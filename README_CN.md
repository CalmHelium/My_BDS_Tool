# My BDS MaintenanceTool

**My BDS MaintenanceTool** is a Windows-based maintenance and management tool for **Minecraft Bedrock Dedicated Server (BDS)**.

It is designed around a single-file PowerShell architecture with internally separated functional components. The tool keeps the interactive console, backup operations, watchdog, logging, crash protection, and process identification logically independent while allowing them to communicate with each other.

> **Current development stage:** Early development / experimental release
> **Suggested version:** `v0.5.x`

---

## Table of Contents

* [Overview](#overview)
* [Core Architecture](#core-architecture)
* [Main Features](#main-features)

  * [Interactive Console](#interactive-console)
  * [BDS Input and Output Pipes](#bds-input-and-output-pipes)
  * [Backup System](#backup-system)
  * [Watchdog](#watchdog)
  * [Logging System](#logging-system)
  * [Crash Logs](#crash-logs)
  * [Process Identification](#process-identification)
  * [Checkpoints and State Synchronization](#checkpoints-and-state-synchronization)
* [BDS Process Detection](#bds-process-detection)
* [Console Commands](#console-commands)
* [Configuration](#configuration)
* [Log Format](#log-format)
* [File Structure](#file-structure)
* [Startup](#startup)
* [Shutdown Behavior](#shutdown-behavior)
* [Unexpected Termination](#unexpected-termination)
* [Backup Behavior](#backup-behavior)
* [Requirements](#requirements)
* [Design Goals](#design-goals)
* [Current Limitations](#current-limitations)
* [Versioning](#versioning)
* [License](#license)

---

## Overview

My BDS MaintenanceTool provides a unified management environment for a Bedrock Dedicated Server.

Instead of allowing BDS and the management program to compete directly for the same console input, the architecture separates their communication channels:

```text
                    My BDS MaintenanceTool
                    Main Console Process
                             │
             ┌───────────────┴───────────────┐
             │                               │
       BackupTool Logic                 Watchdog Logic
             │                               │
             │                         Log / Crash State
             │                               │
             └───────────────┬───────────────┘
                             │
                       BDS Process
                             │
                  ┌──────────┴──────────┐
                  │                     │
               stdin                 stdout/stderr
                  │                     │
                  └────── Pipes ───────┘
```

The main console remains responsible for interactive operation, while BDS input and output are redirected through pipes.

This allows BDS output to be displayed inside the same console while also making it available to the logging subsystem.

[Click to back to contents](#table-of-contents)

---

## Core Architecture

The tool is implemented as a single PowerShell script, but internally behaves as several cooperating components.

### Console

The console component is responsible for:

* User input.
* User-visible output.
* Command interpretation.
* BDS command forwarding.
* Backup commands.
* Help information.
* Normal shutdown requests.

The console remains the primary interactive component.

### Backup

The backup component is responsible for:

* Starting backups.
* Safely stopping BDS before a backup when required.
* Creating backup archives.
* Cleaning old backups.
* Restarting BDS after backup operations.
* Scheduling automatic backups.

### Watchdog

The watchdog is responsible for emergency protection and persistent logging.

Its responsibilities include:

* Monitoring the main process.
* Maintaining communication with the main process.
* Receiving state updates.
* Buffering log records.
* Periodically flushing buffered logs.
* Handling emergency log persistence.
* Detecting abnormal main-process termination.
* Checking whether BDS is still running.
* Attempting to safely terminate BDS when the main process disappears unexpectedly.

The watchdog is intentionally treated as an independent component rather than merely another function of the main console.

[Click to back to contents](#table-of-contents)

---

## Main Features

### Interactive Console

The main console accepts both MaintenanceTool commands and BDS commands.

Input beginning with `/` is interpreted as a BDS command.

Example:

```text
/help
/list
/stop
```

Input without `/` is interpreted by MaintenanceTool itself.

Example:

```text
help
Now_BC
exit
```

This prevents normal MaintenanceTool commands from accidentally being sent to BDS.

[Click to back to contents](#table-of-contents)

---

### BDS Input and Output Pipes

BDS is started with redirected standard streams.

The communication model is:

```text
MaintenanceTool
      │
      │ command
      ▼
 BDS stdin pipe
      │
      ▼
     BDS
      │
      ├──────────────► stdout pipe
      │
      └──────────────► stderr pipe
                            │
                            ▼
                    MaintenanceTool
```

This provides two important properties:

1. MaintenanceTool retains control of the interactive console.
2. BDS output can be captured and logged.

BDS output is displayed as ordinary console output rather than being treated as a separate interactive terminal.

For example:

```text
[BDS][INFO] Starting Server
[BDS][INFO] Version: 1.26.45.1
[BDS][INFO] Server started.
```

The original BDS severity information such as `INFO` is preserved.

[Click to back to contents](#table-of-contents)

---

### Backup System

The backup subsystem supports scheduled and manually triggered backups.

The existing backup workflow is designed around:

```text
Stop BDS safely
      │
      ▼
Create backup
      │
      ▼
Clean old backups
      │
      ▼
Restart BDS
```

The backup system can use `tar.exe` to create the backup archive.

Automatic backups can be configured through the tool's configuration file.

Manual backup:

```text
Now_BC
```

[Click to back to contents](#table-of-contents)

---

### Watchdog

The watchdog exists primarily for failure handling.

Under normal operation, the main process periodically communicates with the watchdog.

Conceptually:

```text
Main Process                         Watchdog
     │                                  │
     │──── handshake / heartbeat ──────►│
     │                                  │
     │──── state update ───────────────►│
     │                                  │
     │──── heartbeat ──────────────────►│
     │                                  │
     X  unexpected termination           │
                                        │
                         heartbeat timeout
                                        │
                                        ▼
                              emergency handling
```

The watchdog does not need to assume that the main process will always reach its normal shutdown code.

If the main process disappears unexpectedly, the watchdog can therefore continue operating independently.

[Click to back to contents](#table-of-contents)

---

### Logging System

Logging is deliberately separated from the main console.

The intended architecture is:

```text
Main Console
     │
     │ log records
     ▼
Watchdog RAM Buffer
     │
     ├── periodic flush
     ├── buffer threshold flush
     ├── date transition flush
     └── emergency flush
             │
             ▼
        local log file
```

This avoids making every console event immediately perform a filesystem write.

The watchdog can temporarily keep log records in memory and periodically append them to disk.

This is especially useful when the main process terminates unexpectedly.

The log file is therefore not dependent solely on the main process reaching its final cleanup code.

[Click to back to contents](#table-of-contents)

---

### Crash Logs

Crash logs are intended to preserve information about abnormal termination.

Normal logs use:

```text
.log
```

Crash information uses:

```text
.crashlog
```

The crash-log mechanism is intended to capture information that would otherwise be lost when the main process closes unexpectedly.

Examples of information that may be relevant include:

* Last known application state.
* Last completed checkpoint.
* Last watchdog communication.
* Last known BDS state.
* Last known BDS PID.
* Last known process paths.
* Recent log records.
* Failure-related state information.

The crash log is supplementary to the normal log rather than a replacement for it.

[Click to back to contents](#table-of-contents)

---

### Process Identification

The tool may have several cooperating processes or components.

For that reason, identifying a process only by its PID is insufficient.

The process identity information is designed to include both:

```text
PID
Executable Path
```

A process can therefore be verified using a combination such as:

```text
Expected executable path
+
Expected PID
```

For BDS, the tool also uses the configured UDP server ports when verifying the server.

[Click to back to contents](#table-of-contents)

---

### Checkpoints and State Synchronization

Important operations use checkpoints.

Before or during a significant state transition, the main component can notify the watchdog of the new state.

Conceptually:

```text
Checkpoint A
    │
    ▼
Notify Watchdog
    │
    ▼
Perform operation
    │
    ▼
Checkpoint B
    │
    ▼
Notify Watchdog
```

This gives the watchdog information about what the main process was doing immediately before an unexpected termination.

Examples of useful state transitions include:

* Startup.
* BDS startup.
* BDS running.
* Backup preparation.
* BDS shutdown.
* Backup creation.
* Backup cleanup.
* BDS restart.
* Normal shutdown.
* Emergency shutdown.

[Click to back to contents](#table-of-contents)

---

## BDS Process Detection

BDS detection is intentionally stricter than simply searching for a process named:

```text
bedrock_server.exe
```

The tool keeps the expected executable path and PID associated with the BDS instance.

The watchdog can then verify that the candidate process corresponds to the expected BDS instance.

In addition, the BDS server ports are checked.

The relevant conditions are treated as an **AND** relationship:

```text
Executable Path matches
        AND
PID matches the recorded process
        AND
server-port matches
        AND
server-portv6 matches
```

The server ports are UDP ports because Minecraft Bedrock Dedicated Server uses UDP for gameplay traffic.

Example configuration:

```text
server-port   = 63500
server-portv6 = 63501
```

The purpose of this mechanism is to avoid accidentally terminating an unrelated process.

[Click to back to contents](#table-of-contents)

---

## Console Commands

### `help`

Displays the available commands.

```text
help
```

### `Now_BC`

Immediately starts a backup operation.

```text
Now_BC
```

### `/command`

Sends a command directly to BDS.

```text
/list
```

The leading `/` is used by MaintenanceTool to distinguish BDS commands from MaintenanceTool commands.

### `exit`

Requests a normal shutdown.

```text
exit
```

The normal shutdown sequence attempts to stop BDS safely before the main process exits.

[Click to back to contents](#table-of-contents)

---

## Configuration

The tool reads its BDS and backup-related configuration from the configuration files used by the project.

Typical configuration information includes:

* BDS executable location.
* World selection.
* Backup directory.
* Backup mode.
* Automatic backup time.
* Backup cleanup settings.
* Number of backups to retain.
* Shutdown timeout.
* BDS UDP server ports.

An example configuration conceptually looks like:

```text
BDS executable
World
Backup directory
Backup mode
Automatic backup time
Cleanup enabled
Keep backups
Shutdown timeout
server-port
server-portv6
```

The exact configuration syntax is determined by the current script version.

[Click to back to contents](#table-of-contents)

---

## Log Format

The console and log system use a compact time-based format.

When the minute changes, a minute marker is written:

```text
[2026-09-10-19-21]
```

Normal entries within that minute use seconds:

```text
[05] [BDS][INFO] Server started.
[08] [BackupTool][Output] Backup completed.
[12] [BackupTool][Input] Now_BC
```

BDS severity information is preserved:

```text
[BDS][INFO]
[BDS][WARN]
[BDS][ERROR]
```

The exact source and direction metadata may additionally identify whether a record originated from:

```text
BDS
BackupTool
```

and whether it represents:

```text
Input
Output
```

The important distinction is that BDS `INFO` information remains visible instead of being discarded.

[Click to back to contents](#table-of-contents)

---

## File Structure

A typical deployment is conceptually structured as follows:

```text
My BDS MaintenanceTool/
│
├── My_BDS_MaintenanceTool.bat
├── My_BDS_MaintenanceTool.ps1
│
├── bedrock_server.exe
├── server.properties
│
├── worlds/
│   └── <world>/
│
├── MyBackUp/
│
├── My_BDS_Tools_logs/
│   ├── YYYY-MM-DD-log.log
│   └── YYYY-MM-DD-crashlog.crashlog
│
└── My_Backup.ini
```

The actual directory contents depend on the deployment and configuration.

The startup batch file is intended to launch the PowerShell maintenance program without requiring changes to the BDS startup configuration.

[Click to back to contents](#table-of-contents)

---

## Startup

The normal startup flow is approximately:

```text
Start BAT
   │
   ▼
Start PowerShell
   │
   ▼
Initialize MaintenanceTool
   │
   ▼
Load configuration
   │
   ▼
Validate BDS configuration
   │
   ▼
Start watchdog
   │
   ▼
Register process identity information
   │
   ▼
Start BDS
   │
   ▼
Redirect BDS stdin/stdout/stderr
   │
   ▼
Enter main console loop
```

The main console remains available while BDS runs.

[Click to back to contents](#table-of-contents)

---

## Shutdown Behavior

### Normal Shutdown

A normal shutdown follows a controlled sequence:

```text
User requests exit
       │
       ▼
Notify watchdog
       │
       ▼
Send BDS "stop"
       │
       ▼
Wait for BDS termination
       │
       ▼
Flush / finalize state
       │
       ▼
Terminate watchdog
       │
       ▼
Exit MaintenanceTool
```

The goal is to allow BDS to perform its own normal shutdown procedures.

The tool does not treat force termination as the preferred normal shutdown method.

[Click to back to contents](#table-of-contents)

---

## Unexpected Termination

The watchdog exists specifically because the normal shutdown sequence cannot be guaranteed.

For example:

```text
MaintenanceTool
      │
      X
   crashes
      │
      │
      ▼
Watchdog remains alive
      │
      ├── detect missing heartbeat
      │
      ├── flush RAM log buffer
      │
      ├── create/update crashlog
      │
      ├── verify BDS
      │
      └── attempt emergency BDS shutdown
```

This is intentionally different from normal shutdown.

When the main process has already disappeared, preserving logs and preventing an orphaned BDS process becomes more important than maintaining the normal graceful shutdown path.

The watchdog may therefore use emergency termination methods when necessary.

[Click to back to contents](#table-of-contents)

---

## Backup Behavior

The backup system is designed so that archive creation does not need to become part of the interactive console's primary responsibilities.

The logical sequence is:

```text
Backup requested
      │
      ▼
Checkpoint
      │
      ▼
Notify watchdog
      │
      ▼
Safely stop BDS
      │
      ▼
Create backup archive
      │
      ▼
Clean old backups
      │
      ▼
Restart BDS
      │
      ▼
Checkpoint
      │
      ▼
Return to normal operation
```

This separation makes it easier to keep the console responsive while maintenance operations are performed.

[Click to back to contents](#table-of-contents)

---

## Requirements

The current project is intended for a Windows environment.

Expected components include:

* Windows.
* Windows PowerShell 5.1.
* Minecraft Bedrock Dedicated Server.
* `bedrock_server.exe`.
* `server.properties`.
* `tar.exe` for backup archive creation.
* Permission to create and manage the required processes.
* Permission to write the backup and log directories.

The tool uses Windows-specific process and IPC mechanisms, so it is not intended to be a cross-platform PowerShell application.

[Click to back to contents](#table-of-contents)

---

## Design Goals

The project is built around several principles.

### 1. Keep the console under one owner

The main console should remain controlled by MaintenanceTool.

BDS should not directly compete with the management program for console input.

### 2. Capture BDS output

BDS output should remain visible while also being available to the logging system.

### 3. Separate responsibilities

The console, backup logic, and watchdog should be logically independent even though they are contained in one script.

### 4. Preserve state

Important state changes should be communicated to the watchdog before potentially dangerous operations.

### 5. Survive abnormal termination

The watchdog should continue operating when possible even if the main process disappears.

### 6. Avoid unnecessary filesystem writes

Logs can be buffered in RAM and periodically flushed instead of forcing every event to perform a disk operation.

### 7. Identify processes precisely

PID alone is not considered sufficient for identifying an important process.

Executable path and other identifying information are retained where appropriate.

### 8. Protect the BDS instance

Emergency shutdown logic should avoid accidentally terminating an unrelated process.

[Click to back to contents](#table-of-contents)

---

## Current Limitations

This project is still under development.

The following areas may continue to change:

* Watchdog communication mechanisms.
* Log buffering implementation.
* Crash-log contents.
* Process identification.
* Emergency BDS shutdown behavior.
* Backup execution architecture.
* Console input rendering.
* Console character handling.
* BDS output ordering between stdout and stderr.
* Configuration format.
* Internal inter-component communication.

The project should therefore be considered experimental rather than production-hardened software.

[Click to back to contents](#table-of-contents)

---

## Versioning

The current architecture represents a significant transition from the original backup-oriented design.

The project is therefore better described as an early `v0.x` release rather than a stable `v1.0` release.

A reasonable development-stage designation is:

```text
v0.5.x
```

A future `v1.0` release should represent a point where the following are considered stable:

* Console behavior.
* BDS process management.
* Backup behavior.
* Watchdog behavior.
* Logging.
* Crash recovery.
* Configuration handling.
* Process identification.

[Click to back to contents](#table-of-contents)

---

## License

No specific open-source license is currently defined by this README.

If this project is published publicly, a license should be added to the repository before redistributing the software under an explicit open-source license.

[Click to back to contents](#table-of-contents)

---

## Project Status

**My BDS MaintenanceTool is an experimental maintenance and management tool for Minecraft Bedrock Dedicated Server.**

The architecture is intentionally modular internally while remaining deployable as a small, portable set of files.

The long-term goal is to provide a reliable maintenance layer around BDS without requiring users to manually manage several independent applications.

**Current status: `v0.5.x — Experimental Development`**
