# My BDS MaintenanceTool

A Windows PowerShell 5.1 maintenance tool for **Minecraft Bedrock Dedicated Server (BDS)**.

My BDS MaintenanceTool is designed to provide a single, portable maintenance environment for a BDS installation, combining:

- Interactive console management
- BDS stdin/stdout/stderr redirection
- BDS console output capture
- Automatic and manual backups
- Backup cleanup
- Process identity tracking
- Watchdog-based failure protection
- Shared-memory logging
- CrashLog generation
- BDS process verification
- State checkpoints
- Safe BDS shutdown and restart

The tool is implemented as a **single PowerShell script**, while internally separating its responsibilities into several relatively independent execution domains.

> Main script: `My_BDS_MaintenanceTool.ps1`
>
> Launcher: `My_BDS_MaintenanceTool.bat`
>
> Chinese documentation: [`README_CN.md`](README_CN.md)

---

## Table of Contents

- [Overview](#overview)
- [Design Goals](#design-goals)
- [Architecture](#architecture)
- [Console](#console)
- [BDS Communication](#bds-communication)
- [BDS Output Handling](#bds-output-handling)
- [Command System](#command-system)
- [Automatic Backups](#automatic-backups)
- [Backup Workflow](#backup-workflow)
- [Watchdog](#watchdog)
- [Process Identity Memory](#process-identity-memory)
- [BDS Process Identification](#bds-process-identification)
- [Shared Log Ring Buffer](#shared-log-ring-buffer)
- [Logging](#logging)
- [Log Time Format](#log-time-format)
- [CrashLog](#crashlog)
- [State Checkpoints](#state-checkpoints)
- [BDS Startup](#bds-startup)
- [Safe BDS Shutdown](#safe-bds-shutdown)
- [Configuration](#configuration)
- [Directory Layout](#directory-layout)
- [Launching the Tool](#launching-the-tool)
- [Console Display](#console-display)
- [Error Handling](#error-handling)
- [Unexpected BDS Exit](#unexpected-bds-exit)
- [Failure Protection](#failure-protection)
- [Design Summary](#design-summary)

---

# Overview

My BDS MaintenanceTool is intended to operate as a long-running maintenance layer around a Minecraft Bedrock Dedicated Server.

It is not merely a BDS launcher.

Its responsibilities are divided into several logical domains:

```text
                    My_BDS_MaintenanceTool.ps1
                              │
              ┌───────────────┼────────────────┐
              │               │                │
              ▼               ▼                ▼
           Console          Backup           Watchdog
              │               │                │
              │               │                │
              ▼               ▼                ▼
          BDS Pipes        Backup Logic      Logging
              │                              Protection
              │
       ┌──────┴──────┐
       ▼             ▼
    BDS stdin    BDS stdout/stderr
