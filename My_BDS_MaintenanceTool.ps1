# My BDS Maintenance Tool
# Windows PowerShell 5.1

param(
    [switch]$Watchdog,
    [int]$WatchParentPid = 0,
    [string]$WatchBDSPath = "",
    [string]$WatchBDSPathBase64 = "",
    [int]$WatchServerPort = 0,
    [int]$WatchServerPortV6 = 0,
    [string]$WatchLogDirectory = "",
    [string]$WatchLogMapName = "",
    [string]$WatchIdentityMapName = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ScriptPath = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($script:ScriptPath)) {
    $script:ScriptPath = Join-Path $Root "My_BDS_MaintenanceTool.ps1"
}

# ============================================================
# Shared RAM log buffer
# ============================================================
# The manager publishes formatted log records into a named shared-memory ring buffer.
# ONLY the independent watchdog writes log files to disk.
# This preserves a recent log snapshot even if the manager terminates
# unexpectedly.
if (-not ("BDSSharedLogBuffer" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Threading;

public static class BDSSharedLogBuffer
{
    private const int Capacity = 4 * 1024 * 1024;
    private const int HeaderSize = 12;
    private const int ReadOffset = 0;
    private const int WriteOffset = 4;
    private const int UsedOffset = 8;

    private static MemoryMappedFile Map;
    private static Mutex Lock;
    private static EventWaitHandle FlushEvent;
    private static MemoryMappedViewAccessor View;

    public static void Open(string name)
    {
        if (String.IsNullOrWhiteSpace(name)) throw new ArgumentException("Shared log map name is empty.");
        if (Map != null) return;

        Map = MemoryMappedFile.CreateOrOpen(name, HeaderSize + Capacity, MemoryMappedFileAccess.ReadWrite);
        Lock = new Mutex(false, name + ".mutex");
        FlushEvent = new EventWaitHandle(false, EventResetMode.AutoReset, name + ".flush");
        View = Map.CreateViewAccessor(0, HeaderSize + Capacity, MemoryMappedFileAccess.ReadWrite);

        bool taken = false;
        try
        {
            Lock.WaitOne();
            taken = true;
            int readPos = View.ReadInt32(ReadOffset);
            int writePos = View.ReadInt32(WriteOffset);
            int used = View.ReadInt32(UsedOffset);
            if (readPos < 0 || readPos >= Capacity ||
                writePos < 0 || writePos >= Capacity ||
                used < 0 || used > Capacity)
            {
                View.Write(ReadOffset, 0);
                View.Write(WriteOffset, 0);
                View.Write(UsedOffset, 0);
            }
        }
        finally
        {
            if (taken) Lock.ReleaseMutex();
        }
    }

    public static bool Append(string text)
    {
        if (Map == null) throw new InvalidOperationException("Shared log buffer is not open.");
        if (text == null) text = "";
        byte[] data = Encoding.UTF8.GetBytes(text);
        if (data.Length == 0) return true;
        if (data.Length > Capacity) return false;

        bool taken = false;
        try
        {
            Lock.WaitOne();
            taken = true;

            int readPos = View.ReadInt32(ReadOffset);
            int writePos = View.ReadInt32(WriteOffset);
            int used = View.ReadInt32(UsedOffset);

            if (readPos < 0 || readPos >= Capacity ||
                writePos < 0 || writePos >= Capacity ||
                used < 0 || used > Capacity)
            {
                readPos = 0; writePos = 0; used = 0;
                View.Write(ReadOffset, 0);
                View.Write(WriteOffset, 0);
                View.Write(UsedOffset, 0);
            }

            if (data.Length > Capacity - used)
                return false;

            int first = Math.Min(data.Length, Capacity - writePos);
            View.WriteArray<byte>(HeaderSize + writePos, data, 0, first);
            if (first < data.Length)
                View.WriteArray<byte>(HeaderSize, data, first, data.Length - first);

            writePos = (writePos + data.Length) % Capacity;
            used += data.Length;

            View.Write(WriteOffset, writePos);
            View.Write(UsedOffset, used);

            // Wake the watchdog when the ring is getting full. It will drain
            // the buffer before the producer needs to block.
            if (used >= (Capacity * 3 / 4))
                try { FlushEvent.Set(); } catch {}

            return true;
        }
        finally
        {
            if (taken) Lock.ReleaseMutex();
        }
    }

    public static bool WaitForSpace(int milliseconds)
    {
        if (FlushEvent == null) return false;
        return FlushEvent.WaitOne(milliseconds);
    }

    public static void SignalFlush()
    {
        try { if (FlushEvent != null) FlushEvent.Set(); } catch {}
    }

    public static int GetUsed()
    {
        if (Map == null) return 0;
        bool taken = false;
        try {
            Lock.WaitOne(); taken = true;
            return View.ReadInt32(UsedOffset);
        }
        finally { if (taken) Lock.ReleaseMutex(); }
    }

    public static string SnapshotAndClear()
    {
        if (Map == null) return "";
        bool taken = false;
        try
        {
            Lock.WaitOne();
            taken = true;

            int readPos = View.ReadInt32(ReadOffset);
            int writePos = View.ReadInt32(WriteOffset);
            int used = View.ReadInt32(UsedOffset);

            if (used <= 0 || used > Capacity ||
                readPos < 0 || readPos >= Capacity ||
                writePos < 0 || writePos >= Capacity)
            {
                View.Write(ReadOffset, 0);
                View.Write(WriteOffset, 0);
                View.Write(UsedOffset, 0);
                return "";
            }

            byte[] data = new byte[used];
            int first = Math.Min(used, Capacity - readPos);
            View.ReadArray(HeaderSize + readPos, data, 0, first);
            if (first < used)
                View.ReadArray(HeaderSize, data, first, used - first);

            View.Write(ReadOffset, writePos);
            View.Write(UsedOffset, 0);
            View.Flush();

            return Encoding.UTF8.GetString(data);
        }
        finally
        {
            if (taken) Lock.ReleaseMutex();
        }
    }

    public static void Close()
    {
        try { if (View != null) View.Dispose(); } catch {}
        try { if (FlushEvent != null) FlushEvent.Dispose(); } catch {}
        try { if (Lock != null) Lock.Dispose(); } catch {}
        try { if (Map != null) Map.Dispose(); } catch {}
        View = null; FlushEvent = null; Lock = null; Map = null;
    }
}
'@
}

# ============================================================
# Shared process identity RAM
# ============================================================
# Every managed execution unit gets a small named shared-memory identity block.
# Identity is recorded at process creation and consists of PID + exact path,
# plus a per-instance GUID, start time and state. This is deliberately separate
# from the high-volume log ring buffer.
if (-not ("BDSProcessIdentity" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO.MemoryMappedFiles;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class BDSProcessIdentity
{
    private const int SlotCount = 4;
    private const int SlotSize = 1024;
    private const int HeaderSize = 16;
    private static MemoryMappedFile Map;
    private static MemoryMappedViewAccessor View;
    private static Mutex Lock;
    private static string MapName;

    private static int Offset(int slot) { return HeaderSize + (slot * SlotSize); }

    public static void Open(string name)
    {
        if (String.IsNullOrWhiteSpace(name)) throw new ArgumentException("Identity map name is empty.");
        if (Map != null) return;
        MapName = name;
        Map = MemoryMappedFile.CreateOrOpen(name, HeaderSize + (SlotCount * SlotSize), MemoryMappedFileAccess.ReadWrite);
        View = Map.CreateViewAccessor(0, HeaderSize + (SlotCount * SlotSize), MemoryMappedFileAccess.ReadWrite);
        Lock = new Mutex(false, name + ".mutex");
    }

    private static void WriteString(int pos, int maxBytes, string value)
    {
        byte[] data = Encoding.UTF8.GetBytes(value ?? "");
        int count = Math.Min(data.Length, maxBytes - 4);
        View.Write(pos, count);
        if (count > 0) View.WriteArray<byte>(pos + 4, data, 0, count);
        for (int i = count; i < maxBytes - 4; i++) View.Write(pos + 4 + i, (byte)0);
    }

    private static string ReadString(int pos, int maxBytes)
    {
        int count = View.ReadInt32(pos);
        if (count < 0 || count > maxBytes - 4) return "";
        if (count == 0) return "";
        byte[] data = new byte[count];
        View.ReadArray<byte>(pos + 4, data, 0, count);
        return Encoding.UTF8.GetString(data);
    }

    public static void Register(int slot, int pid, string path, string state, string instanceId, long startTicks)
    {
        if (slot < 0 || slot >= SlotCount) throw new ArgumentOutOfRangeException("slot");
        bool taken = false;
        try
        {
            Lock.WaitOne(); taken = true;
            int p = Offset(slot);
            View.Write(p + 0, 0x42494431); // BID1
            View.Write(p + 4, pid);
            View.Write(p + 8, startTicks);
            WriteString(p + 16, 256, instanceId);
            WriteString(p + 276, 256, path);
            WriteString(p + 536, 256, state);
            View.Write(p + 796, DateTime.UtcNow.Ticks);
            View.Flush();
        }
        finally { if (taken) Lock.ReleaseMutex(); }
    }

    public static void UpdateState(int slot, string state)
    {
        if (slot < 0 || slot >= SlotCount) return;
        bool taken = false;
        try
        {
            Lock.WaitOne(); taken = true;
            int p = Offset(slot);
            WriteString(p + 536, 256, state);
            View.Write(p + 796, DateTime.UtcNow.Ticks);
            View.Flush();
        }
        finally { if (taken) Lock.ReleaseMutex(); }
    }

    public static void Clear(int slot, string instanceId)
    {
        if (slot < 0 || slot >= SlotCount) return;
        bool taken = false;
        try
        {
            Lock.WaitOne(); taken = true;
            int p = Offset(slot);
            string current = ReadString(p + 16, 256);
            if (!String.IsNullOrWhiteSpace(instanceId) && current != instanceId) return;
            for (int i = 0; i < SlotSize; i++) View.Write(p + i, (byte)0);
            View.Flush();
        }
        finally { if (taken) Lock.ReleaseMutex(); }
    }

    public static string GetState(int slot)
    {
        if (slot < 0 || slot >= SlotCount) return "";
        bool taken = false;
        try
        {
            Lock.WaitOne(); taken = true;
            int p = Offset(slot);
            int magic = View.ReadInt32(p + 0);
            if (magic != 0x42494431) return "";
            return ReadString(p + 536, 256);
        }
        finally { if (taken) Lock.ReleaseMutex(); }
    }

    public static string Snapshot()
    {
        bool taken = false;
        try
        {
            Lock.WaitOne(); taken = true;
            StringBuilder sb = new StringBuilder();
            string[] names = new string[] { "Console", "Backup", "Watchdog", "BDS" };
            for (int slot = 0; slot < SlotCount; slot++)
            {
                int p = Offset(slot);
                int magic = View.ReadInt32(p + 0);
                if (magic != 0x42494431) continue;
                int pid = View.ReadInt32(p + 4);
                long startTicks = View.ReadInt64(p + 8);
                string instanceId = ReadString(p + 16, 256);
                string path = ReadString(p + 276, 256);
                string state = ReadString(p + 536, 256);
                long updateTicks = View.ReadInt64(p + 796);
                sb.AppendLine(String.Format("[{0}] PID={1}; State={2}; Path={3}; InstanceId={4}; StartUtc={5}; LastUpdateUtc={6}",
                    names[slot], pid, state, path, instanceId,
                    new DateTime(startTicks, DateTimeKind.Utc).ToString("o"),
                    new DateTime(updateTicks, DateTimeKind.Utc).ToString("o")));
            }
            return sb.ToString();
        }
        finally { if (taken) Lock.ReleaseMutex(); }
    }

    public static void Close()
    {
        try { if (View != null) View.Dispose(); } catch {}
        try { if (Lock != null) Lock.Dispose(); } catch {}
        try { if (Map != null) Map.Dispose(); } catch {}
        View = null; Lock = null; Map = null;
    }
}
'@
}

# ============================================================
# One-shot BDS watchdog mode
# ============================================================
# The watchdog is the sole log-file writer. It drains the shared-memory ring
# on demand/high-water mark and periodically, then watches the manager process.
# When the manager disappears for any reason, the watchdog
# verifies the target BDS by ALL THREE conditions on the SAME PID:
#   1) exact bedrock_server.exe path
#   2) configured IPv4 UDP server-port
#   3) configured IPv6 UDP server-portv6
# Only when all three conditions match does it terminate that BDS process.
if ($Watchdog) {
    if (-not [string]::IsNullOrWhiteSpace($WatchBDSPathBase64)) {
        try {
            $WatchBDSPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($WatchBDSPathBase64))
        } catch {
            exit 2
        }
    }

    if ($WatchParentPid -le 0 -or [string]::IsNullOrWhiteSpace($WatchBDSPath) -or $WatchServerPort -le 0 -or $WatchServerPortV6 -le 0 -or [string]::IsNullOrWhiteSpace($WatchLogDirectory) -or [string]::IsNullOrWhiteSpace($WatchLogMapName) -or [string]::IsNullOrWhiteSpace($WatchIdentityMapName)) {
        exit 2
    }

    try { [BDSSharedLogBuffer]::Open($WatchLogMapName) } catch { exit 3 }

    try {
        [BDSProcessIdentity]::Open($WatchIdentityMapName)
        $WatchInstanceId = [guid]::NewGuid().ToString("N")
        $WatchSelf = [System.Diagnostics.Process]::GetCurrentProcess()
        $WatchSelfPath = $PSHOME + "\powershell.exe"
        [BDSProcessIdentity]::Register(2, $WatchSelf.Id, $WatchSelfPath, "Running", $WatchInstanceId, $WatchSelf.StartTime.ToUniversalTime().Ticks)
    } catch { exit 4 }

    if (-not ("BDSWatchdogNative" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class BDSWatchdogNative
{
    private const uint SYNCHRONIZE = 0x00100000;
    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const uint PROCESS_TERMINATE = 0x0001;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const int AF_INET = 2;
    private const int AF_INET6 = 23;
    private const int UDP_TABLE_OWNER_PID = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_UDPROW_OWNER_PID
    {
        public uint dwLocalAddr;
        public uint dwLocalPort;
        public uint dwOwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_UDP6ROW_OWNER_PID
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst=16)]
        public byte[] ucLocalAddr;
        public uint dwLocalScopeId;
        public uint dwLocalPort;
        public uint dwOwningPid;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int processId);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool TerminateProcess(IntPtr processHandle, uint exitCode);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(
        IntPtr hProcess,
        uint flags,
        System.Text.StringBuilder exeName,
        ref uint size);

    [DllImport("iphlpapi.dll", SetLastError=true)]
    private static extern uint GetExtendedUdpTable(
        IntPtr pUdpTable,
        ref int pdwSize,
        bool bOrder,
        int ulAf,
        int TableClass,
        uint Reserved);

    private static ushort PortFromNetworkOrder(uint value)
    {
        ushort p = (ushort)(value & 0xFFFF);
        return (ushort)((p >> 8) | (p << 8));
    }

    private static List<int> GetUdpOwners(int port, int family)
    {
        List<int> result = new List<int>();
        int size = 0;
        uint rc = GetExtendedUdpTable(IntPtr.Zero, ref size, false, family, UDP_TABLE_OWNER_PID, 0);
        if (rc != ERROR_INSUFFICIENT_BUFFER || size <= 0)
            return result;

        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            rc = GetExtendedUdpTable(buffer, ref size, false, family, UDP_TABLE_OWNER_PID, 0);
            if (rc != 0) return result;

            int count = Marshal.ReadInt32(buffer);
            int offset = 4;
            int rowSize = family == AF_INET
                ? Marshal.SizeOf(typeof(MIB_UDPROW_OWNER_PID))
                : Marshal.SizeOf(typeof(MIB_UDP6ROW_OWNER_PID));

            for (int i = 0; i < count; i++)
            {
                IntPtr rowPtr = IntPtr.Add(buffer, offset + (i * rowSize));
                uint localPort;
                uint pid;
                if (family == AF_INET)
                {
                    MIB_UDPROW_OWNER_PID row = (MIB_UDPROW_OWNER_PID)Marshal.PtrToStructure(rowPtr, typeof(MIB_UDPROW_OWNER_PID));
                    localPort = row.dwLocalPort;
                    pid = row.dwOwningPid;
                }
                else
                {
                    MIB_UDP6ROW_OWNER_PID row = (MIB_UDP6ROW_OWNER_PID)Marshal.PtrToStructure(rowPtr, typeof(MIB_UDP6ROW_OWNER_PID));
                    localPort = row.dwLocalPort;
                    pid = row.dwOwningPid;
                }

                if (pid != 0 && PortFromNetworkOrder(localPort) == port && !result.Contains((int)pid))
                    result.Add((int)pid);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
        return result;
    }

    public static bool WaitForParentAndCloseMatchingBDS(
        int parentPid,
        string expectedBdsPath,
        int ipv4Port,
        int ipv6Port)
    {
        IntPtr parent = OpenProcess(SYNCHRONIZE, false, parentPid);
        if (parent == IntPtr.Zero)
            return false;

        try
        {
            uint wait = WaitForSingleObject(parent, 0xFFFFFFFF);
            if (wait == WAIT_FAILED)
                return false;
        }
        finally
        {
            CloseHandle(parent);
        }

        string targetPath = System.IO.Path.GetFullPath(expectedBdsPath).TrimEnd('\\','/');
        HashSet<int> v4 = new HashSet<int>(GetUdpOwners(ipv4Port, AF_INET));
        HashSet<int> v6 = new HashSet<int>(GetUdpOwners(ipv6Port, AF_INET6));

        foreach (int pid in v4)
        {
            // The two configured ports MUST belong to the same PID.
            if (!v6.Contains(pid)) continue;

            IntPtr query = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
            if (query == IntPtr.Zero) continue;

            try
            {
                uint capacity = 32768;
                System.Text.StringBuilder path = new System.Text.StringBuilder((int)capacity);
                if (!QueryFullProcessImageName(query, 0, path, ref capacity)) continue;

                string actualPath;
                try { actualPath = System.IO.Path.GetFullPath(path.ToString()).TrimEnd('\\','/'); }
                catch { continue; }

                if (!String.Equals(actualPath, targetPath, StringComparison.OrdinalIgnoreCase))
                    continue;
            }
            finally
            {
                CloseHandle(query);
            }

            IntPtr terminate = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, false, pid);
            if (terminate == IntPtr.Zero) continue;
            try
            {
                return TerminateProcess(terminate, 1);
            }
            finally
            {
                CloseHandle(terminate);
            }
        }

        return false;
    }

    public static IntPtr OpenParentHandle(int pid)
    {
        return OpenProcess(SYNCHRONIZE, false, pid);
    }

    public static bool IsParentAlive(IntPtr handle)
    {
        if (handle == IntPtr.Zero) return false;
        uint result = WaitForSingleObject(handle, 0);
        return result != WAIT_OBJECT_0 && result != WAIT_FAILED;
    }

    public static void CloseHandlePublic(IntPtr handle)
    {
        if (handle != IntPtr.Zero) CloseHandle(handle);
    }
}
'@
    }

    function Write-WatchdogCrashLog {
        param([string]$Reason)

        try {
            $CrashDirectory = Join-Path $WatchLogDirectory "CrashLogs"
            New-Item -ItemType Directory -Force -Path $CrashDirectory | Out-Null
            $Now = Get-Date
            $Stamp = $Now.ToString("yyyy-MM-dd-HHmmss-fff")
            $Path = Join-Path $CrashDirectory ($Stamp + "-MaintenanceTool.crashlog")
            $Snapshot = ""
            try { $Snapshot = [BDSProcessIdentity]::Snapshot() } catch { $Snapshot = "<identity snapshot unavailable: $($_.Exception.Message)>" }
            $Lines = New-Object System.Text.StringBuilder
            [void]$Lines.AppendLine("My BDS MaintenanceTool CrashLog")
            [void]$Lines.AppendLine(("Time: {0}" -f $Now.ToString("yyyy-MM-dd HH:mm:ss.fff")))
            [void]$Lines.AppendLine(("Reason: {0}" -f $Reason))
            [void]$Lines.AppendLine(("Watchdog PID: {0}" -f $WatchSelf.Id))
            [void]$Lines.AppendLine("")
            [void]$Lines.AppendLine("Process identity snapshot:")
            [void]$Lines.Append($Snapshot)
            [void]$Lines.AppendLine("")
            [void]$Lines.AppendLine("The preceding shared RAM log buffer was flushed by the watchdog before emergency BDS handling.")
            [System.IO.File]::AppendAllText($Path, $Lines.ToString(), [System.Text.UTF8Encoding]::new($false))
        } catch {}
    }

    function Flush-WatchdogSharedLog {
        # This function performs the application's batch commit from the shared
        # RAM ring into the log file. It intentionally does NOT call
        # FlushFileBuffers: normal Windows file I/O is system-cached/write-back,
        # and forcing a physical flush for every batch would defeat the purpose
        # of this watchdog-side batching layer.
        try {
            $Payload = [BDSSharedLogBuffer]::SnapshotAndClear()
            if ([string]::IsNullOrEmpty($Payload)) { return }

            if (-not (Test-Path -LiteralPath $WatchLogDirectory -PathType Container)) {
                New-Item -ItemType Directory -Force -Path $WatchLogDirectory | Out-Null
            }

            $Lines = $Payload -replace "`r`n","`n" -replace "`r","`n" -split "`n",-1
            $CurrentDate = $null
            $Block = New-Object System.Text.StringBuilder

            foreach ($Line in $Lines) {
                if ([string]::IsNullOrEmpty($Line)) { continue }

                $DateMatch = [regex]::Match($Line, '^\[(\d{4}-\d{2}-\d{2})-\d{2}-\d{2}\]$')
                if ($DateMatch.Success) {
                    if ($Block.Length -gt 0 -and $null -ne $CurrentDate) {
                        $Path = Join-Path $WatchLogDirectory ($CurrentDate + ".log")
                        [System.IO.File]::AppendAllText(
                            $Path,
                            $Block.ToString(),
                            [System.Text.UTF8Encoding]::new($false)
                        )
                        [void]$Block.Clear()
                    }
                    $CurrentDate = $DateMatch.Groups[1].Value
                }

                if ($null -eq $CurrentDate) {
                    $CurrentDate = (Get-Date).ToString("yyyy-MM-dd")
                }
                [void]$Block.AppendLine($Line)
            }

            if ($Block.Length -gt 0 -and $null -ne $CurrentDate) {
                $Path = Join-Path $WatchLogDirectory ($CurrentDate + ".log")
                [System.IO.File]::AppendAllText(
                    $Path,
                    $Block.ToString(),
                    [System.Text.UTF8Encoding]::new($false)
                )
            }
        }
        catch {}
    }
    $ParentHandle = [IntPtr]::Zero
    try {
        $ParentHandle = [BDSWatchdogNative]::OpenParentHandle($WatchParentPid)
        if ($ParentHandle -eq [IntPtr]::Zero) {
            Flush-WatchdogSharedLog
        }
        else {
            while ($true) {
                # The timer is only a RAM -> file batch interval. Windows still
                # provides its own system file cache/write-back behavior; we do not
                # force FlushFileBuffers here. High-water and explicit flush signals
                # wake this loop earlier when necessary.
                [void][BDSSharedLogBuffer]::WaitForSpace(1000)

                # Before midnight, drain the current day's RAM batch so the next
                # batch can start cleanly in the next day's log file. This is a
                # file-rotation preparation step, not a disk durability flush.
                $Now = Get-Date
                if ($Now.Hour -eq 23 -and $Now.Minute -eq 59 -and $Now.Second -ge 55) {
                    Flush-WatchdogSharedLog
                    Start-Sleep -Milliseconds 100
                    continue
                }

                Flush-WatchdogSharedLog

                if ([BDSWatchdogNative]::IsParentAlive($ParentHandle)) {
                    continue
                }
                break
            }
        }
    }
    catch {}
    finally {
        Flush-WatchdogSharedLog
        try {
            if ($ParentHandle -ne [IntPtr]::Zero) { [BDSWatchdogNative]::CloseHandlePublic($ParentHandle) }
        } catch {}
    }

    $ConsoleState = ""
    try { $ConsoleState = [BDSProcessIdentity]::GetState(0) } catch {}
    $WasCleanShutdown = ($ConsoleState -eq "ShutdownCompleted")
    if (-not $WasCleanShutdown) {
        Write-WatchdogCrashLog ("Console process disappeared unexpectedly. Last Console state: " + $ConsoleState)
    }

    try {
        [void][BDSWatchdogNative]::WaitForParentAndCloseMatchingBDS(
            $WatchParentPid,
            $WatchBDSPath,
            $WatchServerPort,
            $WatchServerPortV6
        )
    }
    catch {}
    Flush-WatchdogSharedLog
    try { [BDSProcessIdentity]::Clear(2, $WatchInstanceId) } catch {}
    try { [BDSProcessIdentity]::Close() } catch {}
    try { [BDSSharedLogBuffer]::Close() } catch {}
    exit 0
}

Set-Location -LiteralPath $Root

$BDSPath = Join-Path $Root "bedrock_server.exe"
$PropertiesPath = Join-Path $Root "server.properties"
$WorldsPath = Join-Path $Root "worlds"
$ConfigPath = Join-Path $Root "My_Backup.ini"
$BackupDefault = Join-Path $Root "MyBackUp"
$LogDirectory = Join-Path $Root "My_BDS_Tools_logs"
$script:CurrentLogPath = $null
$script:LastLogMinute = $null
$script:ConsoleLastMinute = $null
$script:LogSync = New-Object object

$script:BDSProcess = $null
$script:BDSInputWriter = $null
$script:BDSJobHandle = [IntPtr]::Zero
$script:BDSConPTYHandle = [IntPtr]::Zero
$script:BDSStdoutHandler = $null
$script:BDSErroutHandler = $null
$script:BDSOutputQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
$script:BDSOutputThreads = New-Object System.Collections.Generic.List[System.Threading.Thread]
$script:BDSOutputReaders = New-Object System.Collections.Generic.List[object]
$script:ExitRequested = $false
$script:ShutdownRequested = $false
$script:BackupInProgress = $false
$script:ManagerInputBuffer = New-Object System.Text.StringBuilder
$script:BDSWatchdogProcess = $null
$script:SharedLogMapName = ""
$script:SharedLogEnabled = $false
$script:IdentityMapName = ""
$script:ConsoleInstanceId = [guid]::NewGuid().ToString("N")
$script:BDSInstanceId = ""
$script:BackupInstanceId = ""
$script:WatchdogInstanceId = ""

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

try {
    $Hash = [Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = $Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant()))
        $Hex = (-join ($Bytes | ForEach-Object { $_.ToString("x2") })).Substring(0, 24)
    } finally { $Hash.Dispose() }
    $script:SharedLogMapName = "Local\My_BDS_Backup_Log_" + $Hex
    [BDSSharedLogBuffer]::Open($script:SharedLogMapName)
    $script:SharedLogEnabled = $true
    $script:IdentityMapName = "Local\My_BDS_MaintenanceTool_Identity_" + $Hex
    [BDSProcessIdentity]::Open($script:IdentityMapName)
    $ConsoleProcess = [System.Diagnostics.Process]::GetCurrentProcess()
    [BDSProcessIdentity]::Register(0, $ConsoleProcess.Id, $script:ScriptPath, "Running", $script:ConsoleInstanceId, $ConsoleProcess.StartTime.ToUniversalTime().Ticks)
} catch {
    $script:SharedLogEnabled = $false
$script:IdentityMapName = ""
$script:ConsoleInstanceId = [guid]::NewGuid().ToString("N")
$script:BDSInstanceId = ""
$script:BackupInstanceId = ""
$script:WatchdogInstanceId = ""
}

function Set-MaintenanceCheckpoint {
    param(
        [ValidateSet("Console","Backup","BDS","Watchdog")]
        [string]$Component,
        [Parameter(Mandatory=$true)]
        [string]$State,
        [string]$Detail = ""
    )

    # State-before-action checkpoint: publish the state before the operation begins.
    # The watchdog can therefore reconstruct the last known operation even if the
    # process disappears during that operation.
    try {
        switch ($Component) {
            "Console" { [BDSProcessIdentity]::UpdateState(0, $State) }
            "Watchdog" { if (-not [string]::IsNullOrWhiteSpace($script:IdentityMapName) -and -not [string]::IsNullOrWhiteSpace($script:WatchdogInstanceId)) { [BDSProcessIdentity]::UpdateState(2, $State) } }
            "BDS" { if (-not [string]::IsNullOrWhiteSpace($script:BDSInstanceId)) { [BDSProcessIdentity]::UpdateState(3, $State) } }
        }
    } catch {}

    $Text = if ([string]::IsNullOrWhiteSpace($Detail)) { "[$Component][State] $State" } else { "[$Component][State] $State - $Detail" }
    Write-ConsoleRecord -Source "BackupTool" -Direction "Output" -Content $Text
    Write-ToolLogRecord -Source "BackupTool" -Direction "Output" -Content $Text
}

function Write-BCPrefix {
    # Rainbow prefix: [MyBDSMaintenanceTool]
    $Chars = @(
        @{Text='['; Color='Red'},
        @{Text='M'; Color='DarkYellow'},
        @{Text='y'; Color='Yellow'},
        @{Text='B'; Color='Green'},
        @{Text='D'; Color='Cyan'},
        @{Text='S'; Color='Blue'},
        @{Text='M'; Color='DarkBlue'},
        @{Text='a'; Color='Magenta'},
        @{Text='i'; Color='Magenta'},
        @{Text='n'; Color='Red'},
        @{Text='t'; Color='DarkYellow'},
        @{Text='e'; Color='Yellow'},
        @{Text='n'; Color='Green'},
        @{Text='a'; Color='Cyan'},
        @{Text='n'; Color='Blue'},
        @{Text='c'; Color='DarkBlue'},
        @{Text='e'; Color='Magenta'},
        @{Text='T'; Color='Magenta'},
        @{Text='o'; Color='Red'},
        @{Text='o'; Color='DarkYellow'},
        @{Text='l'; Color='Yellow'},
        @{Text=']'; Color='Green'}
    )
    foreach ($Item in $Chars) {
        Write-Host $Item.Text -ForegroundColor $Item.Color -NoNewline
    }
    Write-Host ' ' -NoNewline
}

function Get-CurrentLogFile {
    $Now = Get-Date
    return (Join-Path $LogDirectory ($Now.ToString("yyyy-MM-dd") + ".log"))
}

function Get-LogTimeState {
    param([datetime]$Now = (Get-Date))

    [pscustomobject]@{
        MinuteKey = $Now.ToString("yyyy-MM-dd HH:mm")
        Marker    = $Now.ToString("yyyy-MM-dd-HH-mm")
        Second    = $Now.ToString("ss")
    }
}

function Ensure-LogMinuteMarker {
    # Log minute markers are published by Write-ToolLogRecord together with
    # the first record of each minute. No file I/O occurs in the manager.
    $Now = Get-Date
    $State = Get-LogTimeState $Now
    return ($script:LastLogMinute -ne $State.MinuteKey)
}
function Write-ConsoleTimeMarker {
    param([datetime]$Now = (Get-Date))

    $State = Get-LogTimeState $Now
    if ($script:ConsoleLastMinute -ne $State.MinuteKey) {
        Write-Host ("[{0}]" -f $State.Marker)
        $script:ConsoleLastMinute = $State.MinuteKey
    }
}

function Write-ConsoleRecord {
    param(
        [ValidateSet("BDS","BackupTool")]
        [string]$Source,
        [ValidateSet("Input","Output")]
        [string]$Direction,
        [AllowEmptyString()]
        [string]$Content,
        [string]$BDSLevel = ""
    )

    $Now = Get-Date
    Write-ConsoleTimeMarker $Now
    $Second = $Now.ToString("ss")

    if ($Source -eq "BDS" -and -not [string]::IsNullOrWhiteSpace($BDSLevel)) {
        Write-Host ("[{0}] [BDS][{1}] {2}" -f $Second, $BDSLevel, $Content)
        return
    }

    if ($Source -eq "BDS") {
        Write-Host ("[{0}] [BDS][{1}] {2}" -f $Second, $Direction, $Content)
        return
    }

    Write-BCPrefix
    Write-Host ("[{0}] [BackupTool][{1}] {2}" -f $Second, $Direction, $Content)
}

function Write-ToolLogRecord {
    param(
        [ValidateSet("BDS","BackupTool")]
        [string]$Source,
        [ValidateSet("Input","Output")]
        [string]$Direction,
        [AllowEmptyString()]
        [string]$Content,
        [string]$BDSLevel = ""
    )

    try {
        $Normalized = if ($null -eq $Content) { "" } else { $Content -replace "`r`n", "`n" -replace "`r", "`n" }
        $Lines = $Normalized -split "`n", -1

        foreach ($Line in $Lines) {
            $LineNow = Get-Date
            $State = Get-LogTimeState $LineNow

            if ($Source -eq "BDS" -and -not [string]::IsNullOrWhiteSpace($BDSLevel)) {
                $Record = "[{0}] [BDS][{1}] {2}" -f $State.Second, $BDSLevel, $Line
            }
            elseif ($Source -eq "BDS") {
                $Record = "[{0}] [BDS][{1}] {2}" -f $State.Second, $Direction, $Line
            }
            else {
                $Record = "[{0}] [BackupTool][{1}] {2}" -f $State.Second, $Direction, $Line
            }

            # The manager NEVER writes log files. It only publishes records
            # to the shared RAM ring buffer consumed by the watchdog.
            $MarkerNeeded = ($script:LastLogMinute -ne $State.MinuteKey)
            if ($MarkerNeeded) {
                $Marker = "[{0}]" -f $State.Marker
                $MarkerBytes = [Text.Encoding]::UTF8.GetByteCount($Marker + "`n")
                $RecordBytes = [Text.Encoding]::UTF8.GetByteCount($Record + "`n")
                $Combined = $Marker + "`n" + $Record + "`n"

                $Written = $false
                for ($Attempt = 0; $Attempt -lt 50 -and -not $Written; $Attempt++) {
                    try { $Written = [BDSSharedLogBuffer]::Append($Combined) } catch { $Written = $false }
                    if (-not $Written) {
                        try { [BDSSharedLogBuffer]::SignalFlush() } catch {}
                        Start-Sleep -Milliseconds 10
                    }
                }
                if ($Written) {
                    $script:LastLogMinute = $State.MinuteKey
                }
                else {
                    # Do not write the file here: logging ownership belongs
                    # exclusively to the watchdog. Keep the record in the
                    # producer retry path rather than creating a race.
                    continue
                }
            }
            else {
                $Written = $false
                for ($Attempt = 0; $Attempt -lt 50 -and -not $Written; $Attempt++) {
                    try { $Written = [BDSSharedLogBuffer]::Append($Record + "`n") } catch { $Written = $false }
                    if (-not $Written) {
                        try { [BDSSharedLogBuffer]::SignalFlush() } catch {}
                        Start-Sleep -Milliseconds 10
                    }
                }
            }
        }
    }
    catch {}
}
function Write-BCLog {
    param(
        [string]$Message,
        [ValidateSet("Success","Info","Warning","Error")]
        [string]$Level = "Info"
    )

    switch ($Level) {
        "Success" { $Color = "Green" }
        "Info"    { $Color = "Yellow" }
        "Warning" { $Color = "DarkYellow" }
        "Error"   { $Color = "Red" }
    }

    Write-ConsoleTimeMarker
    $Now = Get-Date
    $Second = $Now.ToString("ss")
    Write-BCPrefix
    Write-Host ("[{0}] [BackupTool][{1}] {2}" -f $Second, $Level, $Message) -ForegroundColor $Color
    Write-ToolLogRecord -Source "BackupTool" -Direction "Output" -Content $Message
}

function Convert-BDSLineForDisplay {
    param([AllowEmptyString()][string]$Line)

    if ($null -eq $Line) { return [pscustomobject]@{ Content = ""; Level = "" } }

    # BDS normally emits lines like:
    # [2026-09-10 19:21:28:205 INFO] Server started.
    # Keep the BDS severity, but replace the verbose BDS timestamp/header with
    # the manager's unified time header and [BDS][LEVEL] source marker.
    $Match = [regex]::Match($Line, '^\[[^\]]+\s+(INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\]\s?(.*)$')
    if ($Match.Success) {
        $Level = $Match.Groups[1].Value.ToUpperInvariant()
        if ($Level -eq "WARNING") { $Level = "WARN" }
        return [pscustomobject]@{ Content = $Match.Groups[2].Value; Level = $Level }
    }

    return [pscustomobject]@{ Content = $Line; Level = "" }
}

function Write-BDSOutput {
    param([AllowEmptyString()][string]$Message)

    if ($null -eq $Message) { return }

    $Normalized = $Message -replace "`r`n", "`n" -replace "`r", "`n"
    $Lines = $Normalized -split "`n", -1
    foreach ($Line in $Lines) {
        $Parsed = Convert-BDSLineForDisplay $Line
        Write-ConsoleRecord -Source "BDS" -Direction "Output" -Content $Parsed.Content -BDSLevel $Parsed.Level
        Write-ToolLogRecord -Source "BDS" -Direction "Output" -Content $Parsed.Content -BDSLevel $Parsed.Level
    }
}

$DefaultValues = [ordered]@{
    BackupMode      = "time"
    BackupTime      = "03:00"
    CycleMinutes    = "1440"
    BackupDirectory = ".\MyBackUp"
    EnableCleanup   = "false"
    KeepBackups     = "14"
    ShutdownTimeout = "180"
}

if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    $ConfigText = @"
; My BDS Backup Manager

[Backup]

BackupMode=time
BackupTime=03:00
CycleMinutes=1440
BackupDirectory=.\MyBackUp
EnableCleanup=false
KeepBackups=14
ShutdownTimeout=180
"@

    [System.IO.File]::WriteAllText(
        $ConfigPath,
        $ConfigText,
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-BCLog "My_Backup.ini created successfully." "Success"
}

$IniLines = [System.Collections.Generic.List[string]]::new()

foreach ($Line in [System.IO.File]::ReadAllLines(
    $ConfigPath,
    [System.Text.UTF8Encoding]::new($false)
)) {
    [void]$IniLines.Add($Line)
}

$SectionIndex = -1

for ($i = 0; $i -lt $IniLines.Count; $i++) {
    if ($IniLines[$i].Trim() -eq "[Backup]") {
        $SectionIndex = $i
        break
    }
}

if ($SectionIndex -eq -1) {
    [void]$IniLines.Add("")
    [void]$IniLines.Add("[Backup]")
    $SectionIndex = $IniLines.Count - 1
}

$Changed = $false

foreach ($Key in $DefaultValues.Keys) {
    $Found = $false

    for ($i = $SectionIndex + 1; $i -lt $IniLines.Count; $i++) {
        $Trimmed = $IniLines[$i].Trim()

        if ($Trimmed.StartsWith("[") -and $Trimmed.EndsWith("]")) {
            break
        }

        if ($Trimmed -match ('^\s*' + [regex]::Escape($Key) + '\s*=(.*)$')) {
            $Found = $true

            if ([string]::IsNullOrWhiteSpace($Matches[1])) {
                $IniLines[$i] = "$Key=$($DefaultValues[$Key])"
                $Changed = $true
            }

            break
        }
    }

    if (!$Found) {
        [void]$IniLines.Add("$Key=$($DefaultValues[$Key])")
        $Changed = $true
    }
}

if ($Changed) {
    [System.IO.File]::WriteAllLines(
        $ConfigPath,
        $IniLines.ToArray(),
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-BCLog "My_Backup.ini was updated with missing defaults." "Info"
}

function Get-IniValue {
    param(
        [string]$Section,
        [string]$Key
    )

    $Inside = $false

    foreach ($Line in $IniLines) {
        $Trimmed = $Line.Trim()

        if ($Trimmed.StartsWith("[") -and $Trimmed.EndsWith("]")) {
            $CurrentSection = $Trimmed.Substring(1, $Trimmed.Length - 2).Trim()
            $Inside = ($CurrentSection -eq $Section)
            continue
        }

        if (!$Inside) { continue }

        if ($Trimmed -match '^([^=]+)=(.*)$') {
            if ($Matches[1].Trim() -eq $Key) {
                return $Matches[2].Trim()
            }
        }
    }

    return $null
}

$BackupMode = (Get-IniValue "Backup" "BackupMode").ToLowerInvariant()
$BackupTime = Get-IniValue "Backup" "BackupTime"
$CycleMinutesRaw = Get-IniValue "Backup" "CycleMinutes"
$BackupDirectory = Get-IniValue "Backup" "BackupDirectory"
$EnableCleanupRaw = Get-IniValue "Backup" "EnableCleanup"
$KeepBackupsRaw = Get-IniValue "Backup" "KeepBackups"
$ShutdownTimeoutRaw = Get-IniValue "Backup" "ShutdownTimeout"

[int]$CycleMinutes = 0
[bool]$EnableCleanup = $false
[int]$KeepBackups = 0
[int]$ShutdownTimeout = 0

if ($BackupMode -ne "time" -and $BackupMode -ne "cycle") {
    Write-BCLog "BackupMode must be 'time' or 'cycle'." "Error"
    exit 10
}

if (![int]::TryParse($CycleMinutesRaw, [ref]$CycleMinutes) -or $CycleMinutes -lt 1) {
    Write-BCLog "CycleMinutes is invalid." "Error"
    exit 11
}

if ([string]::IsNullOrWhiteSpace($EnableCleanupRaw)) {
    $EnableCleanup = $false
}
elseif ($EnableCleanupRaw -match '^(?i:true|1|yes|on)$') {
    $EnableCleanup = $true
}
elseif ($EnableCleanupRaw -match '^(?i:false|0|no|off)$') {
    $EnableCleanup = $false
}
else {
    Write-BCLog "EnableCleanup must be true or false." "Error"
    exit 12
}

if (![int]::TryParse($KeepBackupsRaw, [ref]$KeepBackups) -or $KeepBackups -lt 0) {
    Write-BCLog "KeepBackups is invalid." "Error"
    exit 12
}

if (![int]::TryParse($ShutdownTimeoutRaw, [ref]$ShutdownTimeout) -or $ShutdownTimeout -lt 1) {
    Write-BCLog "ShutdownTimeout is invalid." "Error"
    exit 13
}

if ($BackupMode -eq "time") {
    try {
        [datetime]::ParseExact(
            $BackupTime,
            "HH:mm",
            [Globalization.CultureInfo]::InvariantCulture
        ) | Out-Null
    }
    catch {
        Write-BCLog "BackupTime must use HH:mm format." "Error"
        exit 14
    }
}

if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
    $BackupDirectory = ".\MyBackUp"
}

if ([System.IO.Path]::IsPathRooted($BackupDirectory)) {
    $BackupPath = [System.IO.Path]::GetFullPath($BackupDirectory)
}
else {
    $BackupPath = [System.IO.Path]::GetFullPath((Join-Path $Root $BackupDirectory))
}

if (!(Test-Path -LiteralPath $BDSPath -PathType Leaf)) {
    Write-BCLog "bedrock_server.exe was not found." "Error"
    exit 20
}

if (!(Test-Path -LiteralPath $PropertiesPath -PathType Leaf)) {
    Write-BCLog "server.properties was not found." "Error"
    exit 21
}

if (!(Test-Path -LiteralPath $WorldsPath -PathType Container)) {
    Write-BCLog "worlds directory was not found." "Error"
    exit 22
}

$LevelName = $null

try {
    $PropertiesLines = Get-Content `
        -LiteralPath $PropertiesPath `
        -Encoding UTF8 `
        -ErrorAction Stop

    foreach ($Line in $PropertiesLines) {
        $Trimmed = $Line.Trim()

        if ($Trimmed.StartsWith("#") -or [string]::IsNullOrWhiteSpace($Trimmed)) {
            continue
        }

        if ($Trimmed -match '^\s*level-name\s*=(.*)$') {
            $LevelName = $Matches[1].Trim()
            break
        }
    }
}
catch {
    Write-BCLog "Could not read server.properties: $($_.Exception.Message)" "Error"
    exit 23
}

if ([string]::IsNullOrWhiteSpace($LevelName)) {
    Write-BCLog "level-name was not found or is empty in server.properties." "Error"
    exit 24
}

if ($LevelName.Contains("\") -or $LevelName.Contains("/") -or $LevelName.Contains(":")) {
    Write-BCLog "Invalid level-name. It must identify a single world directory." "Error"
    exit 25
}

foreach ($Char in [System.IO.Path]::GetInvalidFileNameChars()) {
    if ($LevelName.IndexOf($Char) -ge 0) {
        Write-BCLog "Invalid character found in level-name." "Error"
        exit 26
    }
}

$WorldPath = [System.IO.Path]::GetFullPath((Join-Path $WorldsPath $LevelName))

if (!(Test-Path -LiteralPath $WorldPath -PathType Container)) {
    Write-BCLog "Selected world does not exist:" "Error"
    Write-BCLog $WorldPath "Error"
    Write-BCLog "Backup cancelled. The entire worlds directory will NOT be backed up." "Error"
    exit 27
}

New-Item -ItemType Directory -Force -Path $BackupPath | Out-Null

$TarCommand = Get-Command tar.exe -ErrorAction SilentlyContinue

if ($null -eq $TarCommand) {
    Write-BCLog "tar.exe was not found." "Error"
    exit 28
}

$TarPath = $TarCommand.Source


# ============================================================
# BDS instance / port safety checks
# ============================================================

function Get-ConfiguredBDSPorts {
    $Ports = New-Object System.Collections.Generic.List[int]

    foreach ($Line in $PropertiesLines) {
        $Trimmed = $Line.Trim()
        if ($Trimmed.StartsWith("#") -or [string]::IsNullOrWhiteSpace($Trimmed)) { continue }

        if ($Trimmed -match '^\s*server-port\s*=(.*)$') {
            [int]$Port = 0
            if (![int]::TryParse($Matches[1].Trim(), [ref]$Port) -or $Port -lt 1 -or $Port -gt 65535) {
                throw "server-port is invalid: $($Matches[1].Trim())"
            }
            if ($Ports -notcontains $Port) { [void]$Ports.Add($Port) }
        }
        elseif ($Trimmed -match '^\s*server-portv6\s*=(.*)$') {
            [int]$Port = 0
            if (![int]::TryParse($Matches[1].Trim(), [ref]$Port) -or $Port -lt 1 -or $Port -gt 65535) {
                throw "server-portv6 is invalid: $($Matches[1].Trim())"
            }
            if ($Ports -notcontains $Port) { [void]$Ports.Add($Port) }
        }
    }

    if ($Ports.Count -eq 0) {
        [void]$Ports.Add(19132)
        [void]$Ports.Add(19133)
    }

    return @($Ports)
}

function Get-ConfiguredBDSPortPair {
    $Port4 = 19132
    $Port6 = 19133

    foreach ($Line in $PropertiesLines) {
        $Trimmed = $Line.Trim()
        if ($Trimmed.StartsWith("#") -or [string]::IsNullOrWhiteSpace($Trimmed)) { continue }

        if ($Trimmed -match '^\s*server-port\s*=(.*)$') {
            [int]$Parsed = 0
            if (![int]::TryParse($Matches[1].Trim(), [ref]$Parsed) -or $Parsed -lt 1 -or $Parsed -gt 65535) {
                throw "server-port is invalid: $($Matches[1].Trim())"
            }
            $Port4 = $Parsed
        }
        elseif ($Trimmed -match '^\s*server-portv6\s*=(.*)$') {
            [int]$Parsed = 0
            if (![int]::TryParse($Matches[1].Trim(), [ref]$Parsed) -or $Parsed -lt 1 -or $Parsed -gt 65535) {
                throw "server-portv6 is invalid: $($Matches[1].Trim())"
            }
            $Port6 = $Parsed
        }
    }

    return [pscustomobject]@{
        IPv4 = $Port4
        IPv6 = $Port6
    }
}

function Get-RunningBDSProcesses {
    $Results = @()

    try {
        foreach ($P in @(Get-WmiObject Win32_Process -Filter "Name='bedrock_server.exe'" -ErrorAction Stop)) {
            $Results += [pscustomobject]@{
                ProcessId = [int]$P.ProcessId
                Path      = $P.ExecutablePath
            }
        }
    }
    catch {
        Write-BCLog "Could not enumerate bedrock_server.exe processes: $($_.Exception.Message)" "Error"
    }

    return @($Results)
}

function Get-ListeningPortOwners {
    param([int]$Port)

    $Pids = New-Object System.Collections.Generic.List[int]

    # BDS server-port/server-portv6 are UDP ports. Do not use TCP ownership
    # for BDS identity checks.
    try {
        foreach ($E in @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)) {
            if ($E.OwningProcess -and $E.OwningProcess -ne 0 -and $Pids -notcontains [int]$E.OwningProcess) {
                [void]$Pids.Add([int]$E.OwningProcess)
            }
        }
    } catch {}

    return @($Pids)
}


function Wait-ForBDSStartClearance {
    $TargetPath = [System.IO.Path]::GetFullPath($BDSPath).TrimEnd('\','/')

    while ($true) {
        $Blocked = $false
        $Running = @(Get-RunningBDSProcesses)

        foreach ($P in $Running) {
            if ([string]::IsNullOrWhiteSpace($P.Path)) {
                Write-BCLog "A running bedrock_server.exe (PID=$($P.ProcessId)) has an unknown executable path. BDS startup is paused." "Error"
                $Blocked = $true
                continue
            }

            $RunningPath = [System.IO.Path]::GetFullPath($P.Path).TrimEnd('\','/')
            if ([string]::Equals($RunningPath, $TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
                Write-BCLog "The BDS at this directory is already running. PID=$($P.ProcessId)" "Error"
                Write-BCLog "It will NOT be killed or taken over." "Error"
                $Blocked = $true
            }
        }

        foreach ($Port in @(Get-ConfiguredBDSPorts)) {
            foreach ($PidMy in @(Get-ListeningPortOwners $Port)) {
                $SameBDS = $false
                foreach ($P in $Running) {
                    if ($P.ProcessId -eq $PidMy -and ![string]::IsNullOrWhiteSpace($P.Path)) {
                        $RunningPath = [System.IO.Path]::GetFullPath($P.Path).TrimEnd('\','/')
                        if ([string]::Equals($RunningPath, $TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
                            $SameBDS = $true
                        }
                    }
                }

                if ($SameBDS) {
                    Write-BCLog "Configured BDS port $Port is occupied by the already-running BDS (PID=$PidMy)." "Error"
                }
                else {
                    try {
                        $Owner = Get-Process -Id $PidMy -ErrorAction SilentlyContinue
                        if ($null -ne $Owner) {
                            Write-BCLog "Configured BDS port $Port is already in use by PID=$PidMy ($($Owner.ProcessName))." "Error"
                        }
                        else {
                            Write-BCLog "Configured BDS port $Port is already in use by PID=$PidMy." "Error"
                        }
                    } catch {
                        Write-BCLog "Configured BDS port $Port is already in use by PID=$PidMy." "Error"
                    }
                }
                $Blocked = $true
            }
        }

        if (!$Blocked) { return $true }

        Write-BCLog "Resolve the BDS/process/port conflict, then press ENTER to check again." "Info"
        [void](Read-Host)
    }
}

if (-not ("BDSJobNative" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class BDSJobNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetInformationJobObject(
        IntPtr hJob,
        int JobObjectInfoClass,
        IntPtr lpJobObjectInfo,
        uint cbJobObjectInfoLength);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public const int JobObjectExtendedLimitInformation = 9;
    public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;

    public static IntPtr CreateKillOnCloseJob()
    {
        IntPtr hJob = CreateJobObject(IntPtr.Zero, null);
        if (hJob == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error());

        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

        int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, buffer, false);
            if (!SetInformationJobObject(hJob, JobObjectExtendedLimitInformation, buffer, (uint)size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return hJob;
        }
        catch
        {
            CloseHandle(hJob);
            throw;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
'@
}

function Close-BDSJob {
    if ($script:BDSJobHandle -ne [IntPtr]::Zero) {
        try { [BDSJobNative]::CloseHandle($script:BDSJobHandle) | Out-Null } catch {}
        [void]($script:BDSJobHandle = [IntPtr]::Zero)
    }
}

function Close-BDSConPTY {
    if ($script:BDSConPTYHandle -ne [IntPtr]::Zero) {
        try { [BDSConPTYNative]::ClosePseudoConsole($script:BDSConPTYHandle) | Out-Null } catch {}
        [void]($script:BDSConPTYHandle = [IntPtr]::Zero)
    }
}

function Start-BDSWatchdog {
    if ($null -ne $script:BDSWatchdogProcess) {
        try { if (-not $script:BDSWatchdogProcess.HasExited) { return } } catch {}
        try { $script:BDSWatchdogProcess.Dispose() } catch {}
        $script:BDSWatchdogProcess = $null
    }

    $ScriptPath = [System.IO.Path]::GetFullPath($script:ScriptPath)
    $ParentPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $PortPair = Get-ConfiguredBDSPortPair
    $Port4 = [int]$PortPair.IPv4
    $Port6 = [int]$PortPair.IPv6
    if ($Port4 -le 0 -or $Port6 -le 0) {
        throw "BDS watchdog requires valid server-port and server-portv6 values."
    }

    $PSExe = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $PSExe -PathType Leaf)) {
        throw "Windows PowerShell executable was not found: $PSExe"
    }

    $BDSPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($BDSPath))

    $Args = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $ScriptPath),
        '-Watchdog',
        '-WatchParentPid', [string]$ParentPid,
        '-WatchBDSPathBase64', $BDSPathBase64,
        '-WatchServerPort', [string]$Port4,
        '-WatchServerPortV6', [string]$Port6,
        '-WatchLogDirectory', ('"{0}"' -f $LogDirectory),
        '-WatchLogMapName', $script:SharedLogMapName,
        '-WatchIdentityMapName', $script:IdentityMapName
    )

    $script:BDSWatchdogProcess = Start-Process -FilePath $PSExe -ArgumentList $Args -WindowStyle Hidden -PassThru -ErrorAction Stop
    try { [BDSSharedLogBuffer]::SignalFlush() } catch {}
    Write-BCLog "BDS watchdog started. It will verify BDS by exact executable path AND UDP server-port AND UDP server-portv6 after manager termination. PID=$($script:BDSWatchdogProcess.Id)" "Info"
}

if (-not ("BDSRedirectOutputThreadFactory" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Concurrent;
using System.Threading;

public sealed class BDSRedirectOutputPump
{
    private readonly TextReader reader;
    private readonly ConcurrentQueue<object> queue;
    private readonly string source;

    public BDSRedirectOutputPump(TextReader reader, ConcurrentQueue<object> queue, string source)
    {
        this.reader = reader;
        this.queue = queue;
        this.source = source;
    }

    public void Run()
    {
        try
        {
            while (true)
            {
                string line = reader.ReadLine();
                if (line == null) break;
                queue.Enqueue(new object[] { source, line });
            }
        }
        catch (ObjectDisposedException) { }
        catch (Exception ex)
        {
            queue.Enqueue(new object[] { source, "[" + source + " read error] " + ex.Message });
        }
    }
}

public static class BDSRedirectOutputThreadFactory
{
    public static Thread Start(BDSRedirectOutputPump pump)
    {
        Thread thread = new Thread(new ThreadStart(pump.Run));
        thread.IsBackground = true;
        thread.Start();
        return thread;
    }
}
'@
}

function Start-BDS {
    Set-MaintenanceCheckpoint -Component "BDS" -State "Starting" -Detail "Preparing redirected stdin/stdout/stderr pipes."
    Write-BCLog "Starting BDS with hidden console and redirected standard streams..." "Info"

    if (-not (Test-Path -LiteralPath $BDSPath -PathType Leaf)) {
        throw "BDS executable was not found: $BDSPath"
    }

    # This version deliberately does NOT use ConPTY. BDS gets ordinary
    # redirected stdin/stdout/stderr pipes. The manager owns the console,
    # and the main loop drains BDS output into the console and log.
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $Process.StartInfo.FileName = $BDSPath
    $Process.StartInfo.WorkingDirectory = $Root
    $Process.StartInfo.UseShellExecute = $false
    $Process.StartInfo.CreateNoWindow = $true
    $Process.StartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $Process.StartInfo.RedirectStandardInput = $true
    $Process.StartInfo.RedirectStandardOutput = $true
    $Process.StartInfo.RedirectStandardError = $true

    try {
        # BDS output is ordinary text. UTF-8 is preferred; invalid byte sequences
        # are replaced instead of terminating the reader.
        try {
            $Process.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false, $false)
            $Process.StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false, $false)
        }
        catch {
            # Windows PowerShell 5.1 may not expose these properties consistently;
            # the StreamReader still remains usable with its default decoding.
        }

        # Create the process first, then immediately create dedicated blocking
        # readers for stdout and stderr. Nothing in these reader threads writes to
        # the console; they only enqueue complete lines for the main loop.
        if (-not $Process.Start()) {
            throw "Process.Start returned false."
        }

        $script:BDSProcess = $Process
        try {
            $script:BDSInstanceId = [guid]::NewGuid().ToString("N")
            $BDSFullPath = [System.IO.Path]::GetFullPath($BDSPath)
            [BDSProcessIdentity]::Register(3, $Process.Id, $BDSFullPath, "Starting", $script:BDSInstanceId, $Process.StartTime.ToUniversalTime().Ticks)
        } catch {}
        $script:BDSOutputQueue = New-Object System.Collections.Concurrent.ConcurrentQueue[object]
        $script:BDSOutputThreads.Clear()
        $script:BDSOutputReaders.Clear()

        $StdoutReader = $Process.StandardOutput
        $StderrReader = $Process.StandardError
        [void]$script:BDSOutputReaders.Add($StdoutReader)
        [void]$script:BDSOutputReaders.Add($StderrReader)

        $StdoutPump = New-Object BDSRedirectOutputPump($StdoutReader, $script:BDSOutputQueue, "BDS stdout")
        $StderrPump = New-Object BDSRedirectOutputPump($StderrReader, $script:BDSOutputQueue, "BDS stderr")
        $StdoutThread = [BDSRedirectOutputThreadFactory]::Start($StdoutPump)
        $StderrThread = [BDSRedirectOutputThreadFactory]::Start($StderrPump)
        [void]$script:BDSOutputThreads.Add($StdoutThread)
        [void]$script:BDSOutputThreads.Add($StderrThread)

        # Job Object is an optional emergency mechanism. ERROR_ACCESS_DENIED is
        # not allowed to prevent BDS from starting; the independent watchdog is
        # still responsible for the final unexpected-shutdown cleanup.
        if ($script:BDSJobHandle -ne [IntPtr]::Zero) {
            try {
                $ProcessHandle = $Process.Handle
                if (-not [BDSJobNative]::AssignProcessToJobObject($script:BDSJobHandle, $ProcessHandle)) {
                    $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    Write-BCLog "BDS Job Object assignment was unavailable (Win32 error $ErrorCode). Watchdog remains the independent emergency shutdown mechanism." "Warning"
                    [void](Close-BDSJob)
                }
            }
            catch {
                Write-BCLog "BDS Job Object assignment was unavailable: $($_.Exception.Message). Watchdog remains the independent emergency shutdown mechanism." "Warning"
                [void](Close-BDSJob)
            }
        }

        # StreamWriter is the only route used to send commands to BDS. BDS never
        # reads the manager's console input directly, so there is no console-input
        # race between the two processes.
        $script:BDSInputWriter = $Process.StandardInput
        $script:BDSInputWriter.AutoFlush = $true

        try { [BDSProcessIdentity]::UpdateState(3, "Running") } catch {}
        Write-BCLog "BDS started hidden with redirected stdin/stdout/stderr; BDS console output is merged into MaintenanceTool. PID=$($Process.Id)" "Success"
    }
    catch {
        try { if ($Process -and !$Process.HasExited) { $Process.Kill() } } catch {}
        try { if ($Process) { $Process.Dispose() } } catch {}
        try { if ($script:BDSInputWriter) { $script:BDSInputWriter.Dispose() } } catch {}
        try { Close-BDSJob } catch {}
        $script:BDSProcess = $null
        $script:BDSInputWriter = $null
        throw
    }
}

function Drain-BDSOutputQueue {
    $Count = 0
    $Item = $null
    while ($script:BDSOutputQueue.TryDequeue([ref]$Item)) {
        if ($null -ne $Item) {
            if ($Item -is [System.Array] -and $Item.Length -ge 2) {
                $Source = [string]$Item[0]
                $Content = [string]$Item[1]
                Write-BDSOutput $Content
            }
            else {
                Write-BDSOutput ([string]$Item)
            }
            $Count++
        }
        $Item = $null
    }
    return $Count
}

function Stop-BDS-Safely {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return $true
    }

    Set-MaintenanceCheckpoint -Component "BDS" -State "Stopping" -Detail "Safe stop requested; no force-kill."

    try {
        if ($Process.HasExited) {
            Write-BCLog "BDS is already stopped." "Info"
            return $true
        }
    }
    catch {
        return $true
    }

    Write-BCLog "Sending 'stop' to BDS..." "Info"

    try {
        $script:BDSInputWriter.WriteLine("stop")
        $script:BDSInputWriter.Flush()
        Write-ConsoleRecord -Source "BDS" -Direction "Input" -Content "stop"
        Write-ToolLogRecord -Source "BDS" -Direction "Input" -Content "stop"
    }
    catch {
        Write-BCLog "Could not send 'stop' to BDS." "Error"
        return $false
    }

    Write-BCLog "Waiting for normal BDS shutdown..." "Info"

    if (!$Process.WaitForExit($ShutdownTimeout * 1000)) {
        Write-BCLog "BDS did not exit within $ShutdownTimeout seconds." "Error"
        Write-BCLog "NO FORCE-KILL WILL BE PERFORMED." "Error"
        return $false
    }

    Write-BCLog "BDS exited normally." "Success"
    try { [BDSProcessIdentity]::Clear(3, $script:BDSInstanceId) } catch {}
    $script:BDSInstanceId = ""
    Close-BDSJob
    return $true
}

function Create-Backup {
    $Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $ZipName = "${LevelName}_$Timestamp.zip"
    $ZipPath = Join-Path $BackupPath $ZipName

    $script:BackupInProgress = $true

    try {
        Write-BCLog "Creating ZIP backup..." "Info"
        Write-BCLog "World: $LevelName" "Info"

        & $TarPath -caf $ZipPath -C $WorldsPath $LevelName

        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe exited with code $LASTEXITCODE."
        }

        if (!(Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
            throw "ZIP file was not created."
        }

        $ZipFile = Get-Item -LiteralPath $ZipPath

        if ($ZipFile.Length -le 0) {
            throw "ZIP file is empty."
        }

        $SizeMB = $ZipFile.Length / 1MB

        Write-BCLog ("Backup successful. Size: {0:N2} MB" -f $SizeMB) "Success"
        return $true
    }
    catch {
        Write-BCLog "Backup failed: $($_.Exception.Message)" "Error"

        if (Test-Path -LiteralPath $ZipPath) {
            Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue
        }

        return $false
    }
    finally {
        $script:BackupInProgress = $false
    }
}

function Cleanup-Backups {
    if (!$EnableCleanup) {
        return
    }

    if ($KeepBackups -eq 0) {
        return
    }

    $Files = @(
        Get-ChildItem `
            -LiteralPath $BackupPath `
            -Filter "${LevelName}_*.zip" `
            -File |
        Sort-Object LastWriteTime -Descending
    )

    if ($Files.Count -le $KeepBackups) {
        return
    }

    foreach ($File in ($Files | Select-Object -Skip $KeepBackups)) {
        try {
            Remove-Item -LiteralPath $File.FullName -Force
            Write-BCLog "Deleted old backup: $($File.Name)" "Success"
        }
        catch {
            Write-BCLog "Could not delete old backup: $($File.Name)" "Error"
        }
    }
}

function Invoke-BackupCycle {
    if ($script:BackupInProgress) {
        Write-BCLog "A backup is already running." "Info"
        return $false
    }

    Set-MaintenanceCheckpoint -Component "Backup" -State "Preparing" -Detail "Backup cycle is about to begin."
    Write-BCLog "========== BACKUP CYCLE START ==========" "Info"

    if ($null -eq $script:BDSProcess) {
        Write-BCLog "BDS process is not available." "Error"
        return $false
    }

    Set-MaintenanceCheckpoint -Component "Backup" -State "StoppingBDS" -Detail "Requesting safe BDS shutdown before archive creation."
    if (!(Stop-BDS-Safely $script:BDSProcess)) {
        Write-BCLog "Backup cancelled because BDS did not shut down safely." "Error"
        return $false
    }

    $script:BDSProcess = $null

    Set-MaintenanceCheckpoint -Component "Backup" -State "Compressing" -Detail "Creating archive with tar.exe."
    if (!(Create-Backup)) {
        Write-BCLog "Backup failed. BDS will remain stopped." "Error"
        return $false
    }

    Set-MaintenanceCheckpoint -Component "Backup" -State "Cleaning" -Detail "Applying backup retention policy."
    Cleanup-Backups

    if ($script:ExitRequested) {
        return $true
    }

    try {
        if (!(Wait-ForBDSStartClearance)) {
            return $false
        }
        Set-MaintenanceCheckpoint -Component "Backup" -State "StartingBDS" -Detail "Restarting BDS after backup."
        Start-BDS
    }
    catch {
        Set-MaintenanceCheckpoint -Component "Backup" -State "Failed" -Detail "BDS restart failed."
        Write-BCLog "BDS restart failed: $($_.Exception.Message)" "Error"
        Write-BCLog "The manager remains running. Resolve the problem, then press ENTER to retry." "Info"
        [void](Read-Host)
        return (Invoke-BackupCycle)
    }

    # Give BDS a short startup window while continuously draining its output.
    # Do not sleep for three seconds with the main output queue unattended.
    $StartupDeadline = [DateTime]::UtcNow.AddSeconds(3)
    while ([DateTime]::UtcNow -lt $StartupDeadline) {
        Drain-BDSOutputQueue
        if ($script:BDSProcess.HasExited) { break }
        Start-Sleep -Milliseconds 25
    }
    Drain-BDSOutputQueue

    if ($script:BDSProcess.HasExited) {
        Write-BCLog "BDS exited immediately after restart." "Error"
        return $false
    }

    Set-MaintenanceCheckpoint -Component "Backup" -State "Completed" -Detail "Backup cycle completed successfully."
    Write-BCLog "========== BACKUP CYCLE COMPLETE ==========" "Success"
    return $true
}

function Get-NextBackupTime {
    if ($BackupMode -eq "cycle") {
        return (Get-Date).AddMinutes($CycleMinutes)
    }

    $Now = Get-Date
    $Hour = [int]$BackupTime.Substring(0,2)
    $Minute = [int]$BackupTime.Substring(3,2)

    $Target = Get-Date -Hour $Hour -Minute $Minute -Second 0 -Millisecond 0

    if ($Target -le $Now) {
        $Target = $Target.AddDays(1)
    }

    return $Target
}

function Send-BDSCommand {
    param([string]$InputCommand)

    if ($null -eq $script:BDSProcess) {
        Write-BCLog "BDS is not running." "Error"
        return
    }

    if ($script:BDSProcess.HasExited) {
        Write-BCLog "BDS is not running." "Error"
        return
    }

    if (!$InputCommand.StartsWith("/")) {
        Write-BCLog "BDS commands must begin with '/'." "Error"
        return
    }

    $Command = $InputCommand.Substring(1)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        Write-BCLog "Empty BDS command." "Error"
        return
    }

    try {
        $script:BDSInputWriter.WriteLine($Command)
        $script:BDSInputWriter.Flush()
        Write-ConsoleRecord -Source "BDS" -Direction "Input" -Content $Command
        Write-ToolLogRecord -Source "BDS" -Direction "Input" -Content $Command
        Write-BCLog "BDS command sent: $InputCommand" "Success"
    }
    catch {
        Write-BCLog "Failed to send BDS command: $($_.Exception.Message)" "Error"
    }
}

function Show-Help {
    Write-BCLog "Commands:" "Info"

    $HelpLines = @(
        "  Now_BC       Run backup immediately.",
        "  /<command>   Send a command to BDS.",
        "  help         Show this help.",
        "  exit         Safely stop BDS and exit."
    )

    foreach ($HelpLine in $HelpLines) {
        Write-ConsoleTimeMarker
        $Now = Get-Date
        $Second = $Now.ToString("ss")
        Write-BCPrefix
        Write-Host ("[{0}] [BackupTool][Output] {1}" -f $Second, $HelpLine) -ForegroundColor Gray
        Write-ToolLogRecord -Source "BackupTool" -Direction "Output" -Content $HelpLine
    }
}

function Read-ManagerInput {
    param(
        [System.Text.StringBuilder]$Buffer
    )

    if (![Console]::KeyAvailable) {
        return $null
    }

    while ([Console]::KeyAvailable) {
        $Key = [Console]::ReadKey($true)

        if ($Key.Key -eq [ConsoleKey]::Enter) {
            $Line = $Buffer.ToString()
            $Buffer.Clear() | Out-Null
            Write-Host ""
            return $Line
        }

        if ($Key.Key -eq [ConsoleKey]::Backspace) {
            if ($Buffer.Length -gt 0) {
                $Buffer.Length--
                Write-Host "`b `b" -NoNewline
            }
            continue
        }

        if ($Key.KeyChar -ne [char]0 -and ![char]::IsControl($Key.KeyChar)) {
            [void]$Buffer.Append($Key.KeyChar)
            Write-Host $Key.KeyChar -NoNewline
        }
    }

    return $null
}

function Clear-ManagerPromptLine {
    try {
        $Width = [Console]::WindowWidth
        if ($Width -lt 1) { return }
        Write-Host ("`r" + (" " * ($Width - 1)) + "`r") -NoNewline
    } catch {}
}

function Show-ManagerPrompt {
    Write-BCPrefix
    Write-Host ">" -ForegroundColor White -NoNewline
    Write-Host " " -NoNewline
    if ($script:ManagerInputBuffer.Length -gt 0) {
        Write-Host $script:ManagerInputBuffer.ToString() -NoNewline
    }
}

$CancelHandler = {
    param($Sender, $EventArgs)

    $EventArgs.Cancel = $true

    if ($script:ShutdownRequested) {
        return
    }

    $script:ShutdownRequested = $true
    $script:ExitRequested = $true

    Write-Host ""
    Write-BCLog "Ctrl+C received. Requesting safe shutdown..." "Info"

    if ($null -ne $script:BDSProcess) {
        try {
            if (!$script:BDSProcess.HasExited) {
                $script:BDSInputWriter.WriteLine("stop")
                $script:BDSInputWriter.Flush()
                Write-ConsoleRecord -Source "BDS" -Direction "Input" -Content "stop"
        Write-ToolLogRecord -Source "BDS" -Direction "Input" -Content "stop"
                Write-BCLog "Sent 'stop' to BDS." "Info"

                if ($script:BDSProcess.WaitForExit($ShutdownTimeout * 1000)) {
                    Write-BCLog "BDS exited normally." "Success"
                    Close-BDSJob
                }
                else {
                    Write-BCLog "BDS did not exit within timeout." "Error"
                    Write-BCLog "NO FORCE-KILL WILL BE PERFORMED." "Error"
                }
            }
        }
        catch {
            Write-BCLog "Error while stopping BDS: $($_.Exception.Message)" "Error"
        }
    }
}

[Console]::add_CancelKeyPress($CancelHandler)

function Handle-ManagerInput {
    param([string]$InputLine)

    if ($null -eq $InputLine) { return }
    if (-not [string]::IsNullOrWhiteSpace($InputLine)) {
        Write-ToolLogRecord -Source "BackupTool" -Direction "Input" -Content $InputLine
    }

    $Command = $InputLine.Trim()

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return
    }

    switch -Regex ($Command) {
        "^Now_BC$" {
            Invoke-BackupCycle | Out-Null
            return
        }

        "^now_bc$" {
            Invoke-BackupCycle | Out-Null
            return
        }

        "^help$" {
            Show-Help
            return
        }

        "^exit$" {
            Write-BCLog "Exit requested." "Info"
            $script:ExitRequested = $true
            return
        }

        "^quit$" {
            Write-BCLog "Exit requested." "Info"
            $script:ExitRequested = $true
            return
        }

        "^/" {
            Send-BDSCommand $Command
            return
        }

        default {
            Write-BCLog "Unknown command. Type 'help'." "Error"
            return
        }
    }
}

Write-Host ""
Set-MaintenanceCheckpoint -Component "Console" -State "Starting" -Detail "MaintenanceTool console is initializing."
[void](Ensure-LogMinuteMarker)
Write-BCLog "My BDS MaintenanceTool started." "Success"
Write-BCLog "World selected by server.properties: $LevelName" "Success"
Write-BCLog "World path: $WorldPath" "Info"
Write-BCLog "Backup directory: $BackupPath" "Info"
Write-BCLog "Backup mode: $BackupMode" "Info"

if ($BackupMode -eq "time") {
    Write-BCLog "Automatic backup time: $BackupTime" "Info"
}
else {
    Write-BCLog "Automatic backup cycle: $CycleMinutes minute(s)" "Info"
}

Write-BCLog "Backup cleanup: $EnableCleanup" "Info"
Write-BCLog "Keep backups: $KeepBackups" "Info"
Write-BCLog "Shutdown timeout: $ShutdownTimeout second(s)" "Info"
Write-BCLog "tar.exe: $TarPath" "Info"
$WatchdogPortPair = Get-ConfiguredBDSPortPair
Write-BCLog "BDS UDP server-port: $($WatchdogPortPair.IPv4)" "Info"
Write-BCLog "BDS UDP server-portv6: $($WatchdogPortPair.IPv6)" "Info"

try {
    Start-BDSWatchdog
}
catch {
    Write-BCLog "BDS watchdog could not be started: $($_.Exception.Message)" "Error"
}

Show-Help
Set-MaintenanceCheckpoint -Component "Console" -State "Running" -Detail "Interactive main loop is ready."

Write-Host ""
Show-ManagerPrompt

# The manager main loop is started before BDS. This guarantees that the
# output queue is already being drained as soon as BDS is created.
$script:BDSStartPending = $true
$script:BDSStartFailurePause = $false
$NextBackup = Get-NextBackupTime

Write-BCLog "Next automatic backup: $($NextBackup.ToString('yyyy-MM-dd HH:mm:ss'))" "Info"

while ($true) {
    # The main loop owns the complete manager lifecycle:
    #   1) consume BDS output, 2) process manager input,
    #   3) check BDS state, 4) check the system clock for backup,
    #   5) start/restart BDS when requested, then repeat.
    # BDS output is always drained before any potentially longer manager action.
    # If BDS has pending output, clear the current prompt first. This keeps BDS
    # logs readable even while the user is typing, then restores the input buffer.
    $HadBDSOutput = ($script:BDSOutputQueue.Count -gt 0)
    if ($HadBDSOutput) { Clear-ManagerPromptLine }
    $BDSOutputCount = Drain-BDSOutputQueue
    if ($BDSOutputCount -gt 0) { Show-ManagerPrompt }

    if ($script:BDSStartFailurePause) {
        [void](Read-Host)
        $script:BDSStartFailurePause = $false
        $script:BDSStartPending = $true
        Show-ManagerPrompt
    }

    if ($script:ExitRequested) {
        break
    }

    # Start BDS from inside the already-running main loop. The output Pipe and
    # its reader are prepared by Start-BDS before CreateProcess, so startup output
    # has a live consumer from the first emitted byte.
    if ($script:BDSStartPending -and $null -eq $script:BDSProcess -and -not $script:BDSStartFailurePause) {
        if (Wait-ForBDSStartClearance) {
            try {
                Start-BDS
                $script:BDSStartPending = $false
                # Let the pipe reader run briefly, then immediately drain it.
                # This is not a startup synchronization requirement; it only
                # reduces visible latency for the first BDS records.
                Start-Sleep -Milliseconds 10
                $HadBDSOutput = ($script:BDSOutputQueue.Count -gt 0)
                if ($HadBDSOutput) { Clear-ManagerPromptLine }
                $BDSOutputCount = Drain-BDSOutputQueue
                if ($BDSOutputCount -gt 0) { Show-ManagerPrompt }
            }
            catch {
                Write-BCLog "BDS startup failed: $($_.Exception.Message)" "Error"
                Write-BCLog "The manager remains running. Resolve the problem, then press ENTER to retry." "Info"
                $script:BDSStartFailurePause = $true
            }
        }
        continue
    }

    if ($null -ne $script:BDSProcess) {
        if ($script:BDSProcess.HasExited) {
            Drain-BDSOutputQueue | Out-Null
            Set-MaintenanceCheckpoint -Component "BDS" -State "UnexpectedExit" -Detail "BDS process exited outside a requested safe shutdown."
            Write-BCLog "BDS exited unexpectedly." "Error"
            Close-BDSJob
            $script:BDSProcess = $null
            $script:BDSInputWriter = $null
            $script:BDSStartPending = $true
            Write-BCLog "Press ENTER to check whether BDS can be started again." "Info"
            [void](Read-Host)
            Show-ManagerPrompt
            continue
        }
    }

    # Backup scheduling is evaluated from the actual system clock on every
    # main-loop iteration. The .ini file defines the time or cycle interval;
    # there is no independent backup timer/thread.
    $Now = Get-Date
    if ($Now -ge $NextBackup) {
        if (!(Invoke-BackupCycle)) {
            break
        }

        # Recalculate from the current system time after the backup completes.
        # For time mode this selects the next configured clock time; for cycle
        # mode it starts the next interval from the current time.
        $NextBackup = Get-NextBackupTime
        Write-BCLog "Next automatic backup: $($NextBackup.ToString('yyyy-MM-dd HH:mm:ss'))" "Info"
        Show-ManagerPrompt
        continue
    }

    $InputLine = Read-ManagerInput $script:ManagerInputBuffer

    if ($null -ne $InputLine) {
        Handle-ManagerInput $InputLine

        if (!$script:ExitRequested) {
            Show-ManagerPrompt
        }
    }

    [void](Ensure-LogMinuteMarker)
    Start-Sleep -Milliseconds 25
}

# Drain any final BDS records already received before writing the shutdown record.
try {
    $HadBDSOutput = ($script:BDSOutputQueue.Count -gt 0)
    if ($HadBDSOutput) { Clear-ManagerPromptLine }
    [void](Drain-BDSOutputQueue)
}
catch {}

Write-Host ""

Set-MaintenanceCheckpoint -Component "Console" -State "ShutdownRequested" -Detail "Main loop has ended; beginning final shutdown."

if (!$script:ShutdownRequested) {
    Write-BCLog "Manager is shutting down." "Info"

    if ($null -ne $script:BDSProcess) {
        try {
            if (!$script:BDSProcess.HasExited) {
                Stop-BDS-Safely $script:BDSProcess | Out-Null
            }
        }
        catch {
            Write-BCLog "Error during final shutdown: $($_.Exception.Message)" "Error"
        }
    }
}

try {
    [Console]::remove_CancelKeyPress($CancelHandler)
}
catch {}

try {
    if ($null -ne $script:BDSInputWriter) {
        $script:BDSInputWriter.Dispose()
        $script:BDSInputWriter = $null
    }
}
catch {}

try { Drain-BDSOutputQueue } catch {}
try {
    foreach ($Reader in @($script:BDSOutputReaders)) { try { $Reader.Dispose() } catch {} }
    foreach ($Thread in @($script:BDSOutputThreads)) {
        try { if ($Thread.IsAlive) { [void]$Thread.Join(500) } } catch {}
    }
    $script:BDSOutputReaders.Clear()
    $script:BDSOutputThreads.Clear()
}
catch {}

try { Close-BDSJob } catch {}

try {
    if ($null -ne $script:BDSProcess) { $script:BDSProcess.Dispose() }
}
catch {}

Set-MaintenanceCheckpoint -Component "Console" -State "ShutdownCompleted" -Detail "All normal shutdown work completed."
Write-BCLog "My BDS MaintenanceTool stopped." "Success"
# Keep the final Console identity/state visible to the watchdog long enough for
# it to classify a normal shutdown versus a crash. The watchdog may overwrite
# the slot on the next launch.
exit 0
