
---

### `README.md`

```markdown
# My BDS MaintenanceTool

> Minecraft Bedrock Dedicated Server Maintenance Tool
>
> Current Version: **v0.1.0**
>
> Status: Initial Development

My BDS MaintenanceTool is a Windows PowerShell 5.1 maintenance tool for Minecraft Bedrock Dedicated Server (BDS).

It is more than a simple BDS launcher.

The project provides an integrated maintenance architecture containing:

- Interactive Console
- BDS stdin/stdout/stderr pipes
- BDS output capture
- BDS console output forwarding
- Automatic backups
- Manual backups
- Backup cleanup
- Precise BDS process identification
- Watchdog
- Shared-memory log buffering
- `.log` logging
- `.crashlog` crash reports
- State checkpoints
- Unexpected-exit detection
- Safe BDS shutdown
- Emergency BDS protection

The project uses a **single PowerShell script with multiple logically separated components**.

Console, Backup, and Watchdog are architecturally separated while remaining deployable as a single `.ps1` file.

---

## Contents

- [Overview](#overview)
- [Design Goals](#design-goals)
- [Architecture](#architecture)
- [Console](#console)
- [Backup](#backup)
- [Watchdog](#watchdog)
- [BDS I/O](#bds-io)
- [BDS Output Handling](#bds-output-handling)
- [Command System](#command-system)
- [Automatic Backups](#automatic-backups)
- [Backup Workflow](#backup-workflow)
- [Process Identification](#process-identification)
- [Shared Memory](#shared-memory)
- [Logging](#logging)
- [CrashLog](#crashlog)
- [State Checkpoints](#state-checkpoints)
- [BDS Startup](#bds-startup)
- [Safe BDS Shutdown](#safe-bds-shutdown)
- [Unexpected Exit Protection](#unexpected-exit-protection)
- [Configuration](#configuration)
- [Directory Layout](#directory-layout)
- [Launching](#launching)
- [Console Display](#console-display)
- [Error Handling](#error-handling)
- [Version Roadmap](#version-roadmap)

---

## Overview

My BDS MaintenanceTool is intended to act as a long-running maintenance layer around a Minecraft Bedrock Dedicated Server.

The overall architecture is:

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
