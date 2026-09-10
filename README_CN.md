# My BDS MaintenanceTool

> Minecraft Bedrock Dedicated Server Maintenance Tool
>
> Current Version: **v0.1.0**
>
> 状态：Initial Development

My BDS MaintenanceTool 是一个面向 Windows PowerShell 5.1 的 Minecraft Bedrock Dedicated Server（BDS）维护工具。

它并不只是一个简单的 BDS 启动器，而是围绕 BDS 构建了一套集成式维护架构，包括：

- 交互式 Console
- BDS 标准输入/输出/错误输出 Pipe
- BDS 输出捕获
- BDS 输出实时显示
- 自动备份
- 手动备份
- 旧备份清理
- BDS 进程精确识别
- Watchdog
- 共享内存日志缓冲
- `.log` 日志
- `.crashlog` 崩溃日志
- 状态检查点
- 异常退出检测
- BDS 安全关闭
- BDS 异常保护

项目采用**单 PowerShell 文件、多逻辑组件**的设计。

也就是说，Console、Backup、Watchdog 在逻辑上相互独立，但仍然可以部署在同一个 `.ps1` 文件中。

---

## 目录

- [项目概览](#项目概览)
- [设计目标](#设计目标)
- [整体架构](#整体架构)
- [Console](#console)
- [Backup](#backup)
- [Watchdog](#watchdog)
- [BDS 输入输出](#bds-输入输出)
- [BDS 输出处理](#bds-输出处理)
- [命令系统](#命令系统)
- [自动备份](#自动备份)
- [备份流程](#备份流程)
- [进程识别](#进程识别)
- [共享内存](#共享内存)
- [日志系统](#日志系统)
- [CrashLog](#crashlog)
- [状态检查点](#状态检查点)
- [BDS 启动](#bds-启动)
- [BDS 安全关闭](#bds-安全关闭)
- [异常退出保护](#异常退出保护)
- [配置文件](#配置文件)
- [目录结构](#目录结构)
- [启动方式](#启动方式)
- [Console 显示](#console-显示)
- [错误处理](#错误处理)
- [版本规划](#版本规划)

---

## 项目概览

My BDS MaintenanceTool 的核心目标是成为 BDS 外部的一个长期运行维护层。

整体关系如下：

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
