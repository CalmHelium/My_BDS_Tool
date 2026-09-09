# My BDS Backup Manager
# Windows PowerShell 5.1

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $Root

$BDSPath = Join-Path $Root "bedrock_server.exe"
$PropertiesPath = Join-Path $Root "server.properties"
$WorldsPath = Join-Path $Root "worlds"
$ConfigPath = Join-Path $Root "My_Backup.ini"
$BackupDefault = Join-Path $Root "MyBackUp"
$LogDirectory = Join-Path $Root "My_Logs"
$LogPath = Join-Path $LogDirectory "My_Backup.log"

$script:BDSProcess = $null
$script:BDSInputWriter = $null
$script:ExitRequested = $false
$script:ShutdownRequested = $false
$script:BackupInProgress = $false
$script:ManagerInputBuffer = New-Object System.Text.StringBuilder

New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null

function Write-BCPrefix {
    Write-Host "[" -ForegroundColor Red -NoNewline
    Write-Host "B" -ForegroundColor DarkYellow -NoNewline
    Write-Host "D" -ForegroundColor Yellow -NoNewline
    Write-Host "S" -ForegroundColor Green -NoNewline
    Write-Host "_" -ForegroundColor Cyan -NoNewline
    Write-Host "B" -ForegroundColor Cyan -NoNewline
    Write-Host "a" -ForegroundColor Blue -NoNewline
    Write-Host "c" -ForegroundColor DarkBlue -NoNewline
    Write-Host "k" -ForegroundColor Magenta -NoNewline
    Write-Host "U" -ForegroundColor Magenta -NoNewline
    Write-Host "p" -ForegroundColor Red -NoNewline
    Write-Host "]" -ForegroundColor DarkYellow -NoNewline
    Write-Host " " -NoNewline
}

function Write-BCLog {
    param(
        [string]$Message,
        [ValidateSet("Success","Info","Error")]
        [string]$Level = "Info"
    )

    switch ($Level) {
        "Success" { $Color = "Green" }
        "Info"    { $Color = "Yellow" }
        "Error"   { $Color = "Red" }
    }

    Write-BCPrefix
    Write-Host $Message -ForegroundColor $Color

    try {
        $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -LiteralPath $LogPath `
            -Value "[$Timestamp] [BDS_BackUp] $Message" `
            -Encoding UTF8 `
            -ErrorAction SilentlyContinue
    }
    catch {}
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

    try {
        foreach ($E in @(Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)) {
            if ($E.OwningProcess -and $E.OwningProcess -ne 0 -and $Pids -notcontains [int]$E.OwningProcess) {
                [void]$Pids.Add([int]$E.OwningProcess)
            }
        }
    } catch {}

    try {
        foreach ($E in @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)) {
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

function Start-BDS {
    Write-BCLog "Starting BDS in a separate console..." "Info"

    if (-not ("BDSProcessNative" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class BDSProcessNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public class STARTUPINFO
    {
        public int cb = Marshal.SizeOf(typeof(STARTUPINFO));
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public class SECURITY_ATTRIBUTES
    {
        public int nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
        public IntPtr lpSecurityDescriptor = IntPtr.Zero;
        public int bInheritHandle = 1;
    }

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CreatePipe(
        out SafeFileHandle hReadPipe,
        out SafeFileHandle hWritePipe,
        SECURITY_ATTRIBUTES lpPipeAttributes,
        int nSize);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool SetHandleInformation(
        SafeFileHandle hObject,
        uint dwMask,
        uint dwFlags);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool CreateProcess(
        string lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr hObject);

    public const uint CREATE_NEW_CONSOLE = 0x00000010;
    public const uint STARTF_USESTDHANDLES = 0x00000100;
    public const uint HANDLE_FLAG_INHERIT = 0x00000001;
}
'@
    }

    $PipeRead = $null
    $PipeWrite = $null
    $SA = New-Object BDSProcessNative+SECURITY_ATTRIBUTES

    try {
        if (-not [BDSProcessNative]::CreatePipe(
            [ref]$PipeRead,
            [ref]$PipeWrite,
            $SA,
            4096
        )) {
            $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CreatePipe failed with Win32 error $ErrorCode."
        }

        # Only the child may inherit the read end.
        if (-not [BDSProcessNative]::SetHandleInformation(
            $PipeWrite,
            [BDSProcessNative]::HANDLE_FLAG_INHERIT,
            0
        )) {
            $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "SetHandleInformation failed with Win32 error $ErrorCode."
        }

        $StartInfo = New-Object BDSProcessNative+STARTUPINFO
        $StartInfo.dwFlags = [BDSProcessNative]::STARTF_USESTDHANDLES
        $StartInfo.hStdInput = $PipeRead.DangerousGetHandle()

        # NULL output/error handles are intentionally used with
        # CREATE_NEW_CONSOLE so the child receives the new console's
        # normal screen buffers.
        $StartInfo.hStdOutput = [IntPtr]::Zero
        $StartInfo.hStdError = [IntPtr]::Zero
        $StartInfo.lpTitle = "BDS - Bedrock Dedicated Server"

        $PI = New-Object BDSProcessNative+PROCESS_INFORMATION
        $CommandLine = '"' + $BDSPath + '"'

        if (-not [BDSProcessNative]::CreateProcess(
            $BDSPath,
            $CommandLine,
            [IntPtr]::Zero,
            [IntPtr]::Zero,
            $true,
            [BDSProcessNative]::CREATE_NEW_CONSOLE,
            [IntPtr]::Zero,
            $Root,
            $StartInfo,
            [ref]$PI
        )) {
            $ErrorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "CreateProcess failed with Win32 error $ErrorCode."
        }

        # The child inherited the read end. The parent keeps only the write end.
        $PipeRead.Dispose()
        $PipeRead = $null

        $Process = [System.Diagnostics.Process]::GetProcessById($PI.dwProcessId)

        [BDSProcessNative]::CloseHandle($PI.hThread) | Out-Null
        [BDSProcessNative]::CloseHandle($PI.hProcess) | Out-Null

        $script:BDSProcess = $Process
        # Wrap ONLY the anonymous-pipe handle. Never open any path inside the BDS directory.
        # The previous code converted the native handle value into a FileStream path, which
        # could produce errors such as trying to open "...\3016" as a file.
        $PipeStream = [System.IO.FileStream]::new(
            $PipeWrite,
            [System.IO.FileAccess]::Write,
            4096,
            $false
        )

        $script:BDSInputWriter = [System.IO.StreamWriter]::new(
            $PipeStream,
            [System.Text.UTF8Encoding]::new($false)
        )
        $script:BDSInputWriter.AutoFlush = $true

        # The FileStream now owns the pipe handle. Do not dispose PipeWrite separately.
        $PipeWrite = $null

        Write-BCLog "BDS started in a separate console. PID=$($Process.Id)" "Success"
    }
    catch {
        if ($null -ne $PipeRead) { try { $PipeRead.Dispose() } catch {} }
        if ($null -ne $PipeWrite) { try { $PipeWrite.Dispose() } catch {} }
        throw
    }
}

function Stop-BDS-Safely {
    param([System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return $true
    }

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

    Write-BCLog "========== BACKUP CYCLE START ==========" "Info"

    if ($null -eq $script:BDSProcess) {
        Write-BCLog "BDS process is not available." "Error"
        return $false
    }

    if (!(Stop-BDS-Safely $script:BDSProcess)) {
        Write-BCLog "Backup cancelled because BDS did not shut down safely." "Error"
        return $false
    }

    $script:BDSProcess = $null

    if (!(Create-Backup)) {
        Write-BCLog "Backup failed. BDS will remain stopped." "Error"
        return $false
    }

    Cleanup-Backups

    if ($script:ExitRequested) {
        return $true
    }

    try {
        if (!(Wait-ForBDSStartClearance)) {
            return $false
        }
        Start-BDS
    }
    catch {
        Write-BCLog "BDS restart failed: $($_.Exception.Message)" "Error"
        Write-BCLog "The manager remains running. Resolve the problem, then press ENTER to retry." "Info"
        [void](Read-Host)
        return (Invoke-BackupCycle)
    }

    Start-Sleep -Seconds 3

    if ($script:BDSProcess.HasExited) {
        Write-BCLog "BDS exited immediately after restart." "Error"
        return $false
    }

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
        Write-BCLog "BDS command sent: /$Command" "Success"
    }
    catch {
        Write-BCLog "Failed to send BDS command: $($_.Exception.Message)" "Error"
    }
}

function Show-Help {
    Write-BCLog "Commands:" "Info"

    Write-Host "  Now_BC      " -ForegroundColor Yellow -NoNewline
    Write-Host "Run backup immediately." -ForegroundColor Gray

    Write-Host "  /<command>  " -ForegroundColor Yellow -NoNewline
    Write-Host "Send a command to BDS." -ForegroundColor Gray

    Write-Host "  help        " -ForegroundColor Yellow -NoNewline
    Write-Host "Show this help." -ForegroundColor Gray

    Write-Host "  exit        " -ForegroundColor Yellow -NoNewline
    Write-Host "Safely stop BDS and exit." -ForegroundColor Gray
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
                Write-BCLog "Sent 'stop' to BDS." "Info"

                if ($script:BDSProcess.WaitForExit($ShutdownTimeout * 1000)) {
                    Write-BCLog "BDS exited normally." "Success"
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
Write-BCLog "My BDS Backup Manager started." "Success"
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

Show-Help

Write-Host ""
Write-BCPrefix
Write-Host ">" -ForegroundColor White -NoNewline
Write-Host " " -NoNewline

while ($true) {
    if (!(Wait-ForBDSStartClearance)) { continue }

    try {
        Start-BDS
    }
    catch {
        Write-BCLog "BDS startup failed: $($_.Exception.Message)" "Error"
        Write-BCLog "The manager remains running. Resolve the problem, then press ENTER to retry." "Info"
        [void](Read-Host)
        continue
    }

    Start-Sleep -Seconds 3

    if ($script:BDSProcess.HasExited) {
        Write-BCLog "BDS exited immediately after startup." "Error"
        Write-BCLog "The manager remains running. Resolve the problem, then press ENTER to retry." "Info"
        [void](Read-Host)
        $script:BDSProcess = $null
        continue
    }

    break
}

$NextBackup = Get-NextBackupTime

Write-BCLog "Next automatic backup: $($NextBackup.ToString('yyyy-MM-dd HH:mm:ss'))" "Info"

while ($true) {
    if ($script:ExitRequested) {
        break
    }

    if ($null -ne $script:BDSProcess) {
        if ($script:BDSProcess.HasExited) {
            Write-BCLog "BDS exited unexpectedly." "Error"
            $script:BDSProcess = $null
            Write-BCLog "Press ENTER to check whether BDS can be started again." "Info"
            [void](Read-Host)

            while ($true) {
                if (!(Wait-ForBDSStartClearance)) { continue }
                try {
                    Start-BDS
                    Start-Sleep -Seconds 3
                    if ($script:BDSProcess.HasExited) {
                        Write-BCLog "BDS exited immediately after restart." "Error"
                        $script:BDSProcess = $null
                        Write-BCLog "Press ENTER to retry." "Info"
                        [void](Read-Host)
                        continue
                    }
                    break
                }
                catch {
                    Write-BCLog "BDS restart failed: $($_.Exception.Message)" "Error"
                    Write-BCLog "Press ENTER to retry. The manager will remain running." "Info"
                    [void](Read-Host)
                }
            }
        }
    }

    if ((Get-Date) -ge $NextBackup) {
        if (!(Invoke-BackupCycle)) {
            break
        }

        $NextBackup = Get-NextBackupTime

        Write-BCLog `
            "Next automatic backup: $($NextBackup.ToString('yyyy-MM-dd HH:mm:ss'))" `
            "Info"

        continue
    }

    $InputLine = Read-ManagerInput $script:ManagerInputBuffer

    if ($null -ne $InputLine) {
        Handle-ManagerInput $InputLine

        if (!$script:ExitRequested) {
            Write-Host ""
            Write-BCPrefix
            Write-Host ">" -ForegroundColor White -NoNewline
            Write-Host " " -NoNewline
        }
    }

    Start-Sleep -Milliseconds 50
}

Write-Host ""

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

Write-BCLog "My BDS Backup Manager stopped." "Success"
exit 0
