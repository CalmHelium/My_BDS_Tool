# My BDS MaintenanceTool

**My BDS MaintenanceTool** 是一个面向 **Minecraft Bedrock Dedicated Server（BDS）** 的 Windows 服务器维护与管理工具。

它采用**单 PowerShell 文件、内部多组件协作**的架构：虽然整个工具可以作为一个文件部署，但内部将控制台交互、BDS 通信、备份、Watchdog、日志、Crashlog、进程识别以及状态检查等功能进行逻辑分离。

> **当前开发阶段：** 早期开发 / 实验版本
> **当前建议版本：** `v0.5.x`

---

## 目录

* [概述](#概述)
* [核心架构](#核心架构)
* [主要功能](#主要功能)

  * [交互式控制台](#交互式控制台)
  * [BDS 输入与输出 Pipe](#bds-输入与输出-pipe)
  * [备份系统](#备份系统)
  * [Watchdog](#watchdog)
  * [日志系统](#日志系统)
  * [Crashlog](#crashlog)
  * [进程识别](#进程识别)
  * [检查点与状态同步](#检查点与状态同步)
* [BDS 进程检测](#bds-进程检测)
* [控制台命令](#控制台命令)
* [配置](#配置)
* [日志格式](#日志格式)
* [文件结构](#文件结构)
* [启动流程](#启动流程)
* [关闭行为](#关闭行为)
* [异常终止](#异常终止)
* [备份行为](#备份行为)
* [运行要求](#运行要求)
* [设计目标](#设计目标)
* [当前限制](#当前限制)
* [版本](#版本)
* [许可证](#许可证)

---

## 概述

My BDS MaintenanceTool 为 Minecraft Bedrock Dedicated Server 提供统一的维护环境。

与让 BDS 和管理程序直接竞争同一个 Console 输入不同，本工具将 BDS 的输入输出通道与 MaintenanceTool 自身的 Console 输入进行分离：

```text
                    My BDS MaintenanceTool
                    主 Console 进程
                           │
             ┌─────────────┴─────────────┐
             │                           │
          Backup                    Watchdog
             │                           │
             │                    日志 / Crash 状态
             │                           │
             └─────────────┬─────────────┘
                           │
                       BDS Process
                           │
                ┌──────────┴──────────┐
                │                     │
             stdin              stdout / stderr
                │                     │
                └─────── Pipe ────────┘
```

主 Console 始终由 MaintenanceTool 接管。

BDS 的标准输入、标准输出和标准错误则通过 Pipe 与 MaintenanceTool 连接。

这样既可以：

* 保持主 Console 的输入控制权；
* 向 BDS 发送命令；
* 获取 BDS 的输出；
* 将 BDS 输出显示在主 Console；
* 将 BDS 输出交给日志系统保存。

[点击返回目录](#目录)

---

## 核心架构

虽然项目最终仍然可以通过一个 PowerShell 文件部署，但其内部并不是一个完全耦合的单体程序。

主要逻辑可以划分为以下几个部分。

### Console

Console 是主要的交互组件，负责：

* 用户输入；
* 用户可见输出；
* MaintenanceTool 命令解析；
* BDS 命令转发；
* 帮助信息；
* 手动备份；
* 正常退出。

Console 是整个工具的主要交互入口。

### Backup

Backup 负责：

* 执行备份；
* 在需要时安全停止 BDS；
* 创建备份压缩包；
* 清理旧备份；
* 重启 BDS；
* 自动备份调度。

Backup 的具体执行过程不会成为 Console 的全部职责。

### Watchdog

Watchdog 是独立于主 Console 的保护组件。

其主要职责包括：

* 监控主进程；
* 与主进程进行握手 / 心跳通信；
* 接收主进程状态更新；
* 缓存日志；
* 定期写入日志；
* 在主进程异常消失时执行紧急处理；
* 保存 Crashlog；
* 检查 BDS 是否仍然存在；
* 在必要时尝试关闭遗留的 BDS。

这种结构的主要目的，是避免：

> 主进程负责记录“主进程自己已经崩溃”。

因为如果主进程已经异常退出，它自然无法执行最后的日志写入代码。

[点击返回目录](#目录)

---

## 主要功能

### 交互式控制台

MaintenanceTool Console 同时支持两种输入：

**以 `/` 开头的输入：**

视为 BDS 命令。

例如：

```text
/help
/list
/gamemode survival
```

**不以 `/` 开头的输入：**

视为 MaintenanceTool 自身命令。

例如：

```text
help
Now_BC
exit
```

因此：

```text
/list
```

会发送给 BDS，而：

```text
help
```

会由 MaintenanceTool 自己处理。

`/` 在这里不是 MaintenanceTool 的命令前缀，而是用于区分 BDS 命令和 MaintenanceTool 命令的识别标记。

[点击返回目录](#目录)

---

### BDS 输入与输出 Pipe

BDS 使用重定向后的标准输入、标准输出和标准错误。

整体结构为：

```text
MaintenanceTool
       │
       │ BDS command
       ▼
   stdin Pipe
       │
       ▼
      BDS
       │
       ├──────────────► stdout Pipe
       │
       └──────────────► stderr Pipe
                              │
                              ▼
                       MaintenanceTool
```

这样可以避免 BDS 与 MaintenanceTool 同时直接抢占 Console 输入。

与此同时，BDS 输出仍然可以实时进入 MaintenanceTool。

例如 BDS 原始输出：

```text
[2026-09-10 19:21:28:205 INFO] Server started.
```

在 MaintenanceTool Console 中可以显示为：

```text
[BDS][INFO] Server started.
```

其中原有的 `INFO` 信息仍然保留。

同样：

```text
[BDS][WARN] ...
[BDS][ERROR] ...
```

也可以保留 BDS 原本的日志等级。

[点击返回目录](#目录)

---

### 备份系统

Backup 系统支持手动备份和自动备份。

典型流程为：

```text
请求备份
   │
   ▼
通知 Watchdog
   │
   ▼
安全停止 BDS
   │
   ▼
创建备份
   │
   ▼
清理旧备份
   │
   ▼
重新启动 BDS
   │
   ▼
恢复正常运行
```

手动立即备份：

```text
Now_BC
```

备份创建使用 Windows 环境中的 `tar.exe`。

自动备份则按照配置中的备份模式和时间执行。

备份过程中产生的重要状态变化也可以先发送给 Watchdog，再执行实际操作。

[点击返回目录](#目录)

---

### Watchdog

Watchdog 是整个工具异常保护机制的重要组成部分。

正常情况下，主进程会定期向 Watchdog 发送确认消息：

```text
主进程                         Watchdog
   │                              │
   │──── heartbeat ──────────────►│
   │                              │
   │──── state update ───────────►│
   │                              │
   │──── heartbeat ──────────────►│
   │                              │
   │──── heartbeat ──────────────►│
   │                              │
```

如果主进程正常运行，Watchdog 会持续收到这些消息。

如果主进程突然消失：

```text
主进程                         Watchdog
   │                              │
   │──── heartbeat ──────────────►│
   │                              │
   X                              │
  崩溃                            │
                                  │
                         heartbeat timeout
                                  │
                                  ▼
                           紧急处理流程
```

Watchdog 可以因此判断：

> 主进程可能已经异常退出。

然后进入紧急处理流程。

[点击返回目录](#目录)

---

### 日志系统

日志写入工作统一由 Watchdog 负责。

主进程并不应该在每产生一条日志时直接进行磁盘写入。

基本结构：

```text
Main Console
      │
      │ log record
      ▼
Watchdog RAM Buffer
      │
      ├── 定时 Flush
      ├── Buffer 达到阈值
      ├── 跨天
      └── 主进程异常退出
              │
              ▼
          本地日志文件
```

这样做的目的主要有两个。

第一，减少频繁的文件系统写入。

第二，即使主进程突然消失，Watchdog 仍然可以把自己 RAM 中保存的日志写入磁盘。

因此：

```text
主进程异常退出
        │
        ▼
Watchdog 仍然存在
        │
        ▼
写入剩余 RAM 日志
        │
        ▼
保存 Crashlog
```

这比单纯依赖主进程的 `finally` 或退出清理代码更加可靠。

[点击返回目录](#目录)

---

### Crashlog

普通日志使用：

```text
.log
```

异常情况使用：

```text
.crashlog
```

Crashlog 的目的不是替代普通日志，而是在异常终止情况下保存最后状态。

可能包含的信息包括：

* 主进程最后状态；
* 最后一个检查点；
* 最后一次 Watchdog 握手；
* 最后已知 BDS 状态；
* BDS PID；
* BDS 可执行文件路径；
* 其他受监控进程的 PID；
* 对应进程路径；
* 最近的日志记录；
* 异常发生前的状态信息。

例如：

```text
主进程状态
BDS 状态
Backup 状态
Watchdog 状态
Last Checkpoint
Last Heartbeat
BDS PID
BDS Path
```

这样即使主程序直接被关闭或发生崩溃，也尽可能能够知道：

> 主程序在消失之前正在做什么。

[点击返回目录](#目录)

---

### 进程识别

由于现在工具内部可能存在多个相互独立的进程或组件，仅通过 PID 判断进程并不可靠。

因此，在创建受监控进程时，会保留配套的识别信息。

最基本的识别信息包括：

```text
PID
Executable Path
```

也就是说：

```text
PID matches
AND
Executable Path matches
```

才认为目标进程是预期的那个进程。

这样可以降低 PID 被其他进程复用后造成误判的风险。

对于 BDS，还会进一步结合：

```text
Executable Path
PID
server-port
server-portv6
```

进行检查。

[点击返回目录](#目录)

---

### 检查点与状态同步

关键操作会设置检查点。

在状态发生改变时，主进程首先向 Watchdog 报告状态，然后执行对应操作。

例如：

```text
Checkpoint A
     │
     ▼
发送状态给 Watchdog
     │
     ▼
执行实际操作
     │
     ▼
操作完成
     │
     ▼
Checkpoint B
     │
     ▼
发送新状态
```

这样如果主进程恰好在操作过程中崩溃，Watchdog 仍然能够知道：

```text
主进程最后一次确认的状态是什么
```

例如：

```text
STARTING
BDS_STARTING
BDS_RUNNING
BACKUP_PREPARING
BDS_STOPPING
BACKUP_RUNNING
BACKUP_CLEANUP
BDS_RESTARTING
SHUTTING_DOWN
```

实际检查点名称会以当前程序实现为准。

[点击返回目录](#目录)

---

## BDS 进程检测

BDS 检测不会简单地使用：

```text
bedrock_server.exe
```

作为唯一条件。

Watchdog 会保存 BDS 的进程信息。

例如：

```text
Expected BDS PID
Expected BDS Executable Path
Expected server-port
Expected server-portv6
```

检测条件之间是 **AND** 关系：

```text
Executable Path matches
        AND
PID matches
        AND
server-port matches
        AND
server-portv6 matches
```

也就是说，只有所有条件都符合时，才认为发现的是目标 BDS。

例如：

```text
BDS executable:
C:\servers\survival server\bedrock-server-1.26.45.1\bedrock_server.exe

PID:
8912

server-port:
63500

server-portv6:
63501
```

Watchdog 不应仅因为发现了另一个名为 `bedrock_server.exe` 的进程，就认为它是当前管理的 BDS。

### UDP 端口

Bedrock Dedicated Server 的游戏通信使用 UDP。

因此这里检查的是：

```text
server-port
server-portv6
```

对应的 UDP 端口，而不是 TCP 端口。

[点击返回目录](#目录)

---

## 控制台命令

### `help`

显示 MaintenanceTool 的帮助信息。

```text
help
```

### `Now_BC`

立即执行备份。

```text
Now_BC
```

### `/command`

向 BDS 发送命令。

例如：

```text
/list
```

MaintenanceTool 会识别开头的 `/`，然后将对应命令发送至 BDS stdin。

### `exit`

请求正常退出。

```text
exit
```

正常退出时，MaintenanceTool 会尝试：

1. 通知 Watchdog；
2. 向 BDS 发送 `stop`；
3. 等待 BDS 正常退出；
4. 完成状态和日志处理；
5. 结束 Watchdog；
6. 退出主程序。

[点击返回目录](#目录)

---

## 配置

MaintenanceTool 的配置主要用于描述 BDS 和备份环境。

典型配置内容包括：

```text
BDS executable path
World
Backup directory
Backup mode
Automatic backup time
Backup cleanup
Keep backups
Shutdown timeout
server-port
server-portv6
```

例如：

```text
BDS:
C:\servers\...\bedrock_server.exe

World:
Survival Room

Backup directory:
C:\servers\...\MyBackUp

server-port:
63500

server-portv6:
63501
```

实际配置文件格式和字段名称以当前程序版本为准。

[点击返回目录](#目录)

---

## 日志格式

Console 时间显示与日志采用统一的时间逻辑。

当分钟发生变化时，打印分钟标记：

```text
[2026-09-10-19-21]
```

同一分钟内的普通日志只需要显示秒：

```text
[05] [BDS][INFO] Server started.
[08] [BackupTool][Output] Backup completed.
[12] [BackupTool][Input] Now_BC
```

BDS 的原始日志等级保持：

```text
[BDS][INFO]
[BDS][WARN]
[BDS][ERROR]
```

而不是将原来的：

```text
[INFO]
```

完全替换掉。

这样既能够明显区分 BDS 和 MaintenanceTool，又不会丢失 BDS 自己的日志等级。

日志还可以附带来源和方向信息：

```text
[BDS][Input]
[BDS][Output]

[BackupTool][Input]
[BackupTool][Output]
```

最终格式以当前版本实现为准。

[点击返回目录](#目录)

---

## 文件结构

典型部署结构可以类似：

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

实际目录结构取决于部署环境和配置。

BAT 启动文件负责启动 PowerShell 主程序。

BDS 本身的文件结构则保持 Minecraft Bedrock Dedicated Server 的正常布局。

[点击返回目录](#目录)

---

## 启动流程

典型启动过程：

```text
启动 BAT
   │
   ▼
启动 PowerShell
   │
   ▼
初始化 MaintenanceTool
   │
   ▼
读取配置
   │
   ▼
检查 BDS 配置
   │
   ▼
启动 Watchdog
   │
   ▼
记录进程识别信息
   │
   ▼
启动 BDS
   │
   ▼
建立 stdin/stdout/stderr Pipe
   │
   ▼
进入主 Console 循环
```

BDS 启动之后：

```text
BDS Output
    │
    ▼
Pipe
    │
    ▼
MaintenanceTool
    │
    ├── Console
    └── Watchdog Log Buffer
```

因此用户仍然可以在一个 Console 中看到 BDS 的输出，同时该输出可以被日志系统记录。

[点击返回目录](#目录)

---

## 关闭行为

### 正常关闭

正常关闭时的目标流程：

```text
用户输入 exit
       │
       ▼
发送状态更新
       │
       ▼
通知 Watchdog
       │
       ▼
发送 BDS stop
       │
       ▼
等待 BDS 正常退出
       │
       ▼
完成日志 / 状态处理
       │
       ▼
关闭 Watchdog
       │
       ▼
退出 MaintenanceTool
```

正常情况下不会优先使用强制终止 BDS 的方式。

这样可以让 BDS 自己完成正常的世界保存和关闭过程。

[点击返回目录](#目录)

---

## 异常终止

异常终止是 Watchdog 存在的主要原因之一。

例如：

```text
MaintenanceTool
       │
       X
     崩溃
       │
       ▼
Watchdog 仍然运行
       │
       ├── 检测 Heartbeat 超时
       │
       ├── Flush RAM Log Buffer
       │
       ├── 写入 Crashlog
       │
       ├── 检查 BDS
       │
       └── 尝试关闭 BDS
```

如果主进程只是正常退出：

```text
Main Process
     │
     ▼
正常发送 shutdown
     │
     ▼
Watchdog 收到确认
     │
     ▼
正常关闭
```

而如果主进程直接被关闭，例如：

```text
点击 Console 的 X
```

或者发生崩溃：

```text
Main Process
     X
```

Watchdog 则可以通过没有继续收到 Heartbeat 来判断异常情况。

此时优先考虑：

1. 保存 RAM 中尚未写入的日志；
2. 创建或追加 Crashlog；
3. 检查 BDS 是否仍然存在；
4. 使用 PID + 路径 + 端口等条件确认目标 BDS；
5. 尝试安全关闭 BDS；
6. 在必要情况下使用紧急终止方式；
7. 最后关闭 Watchdog 自身。

异常情况下允许使用比正常关闭更激进的保护手段，因为此时主进程已经无法继续执行正常关闭流程。

[点击返回目录](#目录)

---

## 备份行为

备份操作的目标流程：

```text
请求 Backup
      │
      ▼
Checkpoint
      │
      ▼
通知 Watchdog
      │
      ▼
安全停止 BDS
      │
      ▼
创建 Backup Archive
      │
      ▼
清理旧 Backup
      │
      ▼
重新启动 BDS
      │
      ▼
Checkpoint
      │
      ▼
恢复正常运行
```

这样 Backup 逻辑可以与 Console 的交互逻辑保持相对独立。

未来如果 Backup 操作需要较长时间，也可以进一步让 Backup 部分拥有更加独立的执行状态，而不会影响主 Console 的职责。

[点击返回目录](#目录)

---

## 运行要求

当前工具面向 Windows 环境。

基本要求包括：

* Windows；
* Windows PowerShell 5.1；
* Minecraft Bedrock Dedicated Server；
* `bedrock_server.exe`；
* `server.properties`；
* `tar.exe`；
* 对必要进程拥有创建和管理权限；
* 对日志目录拥有写入权限；
* 对备份目录拥有写入权限。

由于工具使用 Windows 特有的进程、Pipe 和 IPC 机制，因此它并不是一个以跨平台为目标的 PowerShell 工具。

[点击返回目录](#目录)

---

## 设计目标

### 1. Console 始终由 MaintenanceTool 管理

BDS 不应与 MaintenanceTool 同时争夺同一个 Console 的输入控制权。

### 2. 获取 BDS 输出

BDS 输出应该既能显示给用户，又能进入日志系统。

### 3. 分离不同职责

Console、Backup 和 Watchdog 虽然最终可以存在于同一个 PowerShell 文件中，但内部职责应保持相对独立。

### 4. 保留状态

关键操作开始之前，应尽可能先通知 Watchdog 当前状态。

### 5. 处理异常退出

即使主进程突然消失，Watchdog 也应该尽可能继续完成日志保存和 BDS 保全工作。

### 6. 避免不必要的磁盘写入

日志首先进入 Watchdog 的 RAM Buffer，然后根据：

* 定时；
* Buffer 阈值；
* 跨天；
* 异常退出；

等条件进行 Flush。

### 7. 精确识别进程

PID 不应作为唯一的进程身份依据。

重要进程应该结合：

```text
PID
+
Executable Path
```

以及必要的其他运行状态进行识别。

### 8. 防止误关闭 BDS

Watchdog 在关闭 BDS 前必须尽可能确认目标进程确实是当前 MaintenanceTool 管理的 BDS。

[点击返回目录](#目录)

---

## 当前限制

当前项目仍处于开发阶段。

以下部分未来仍可能发生变化：

* Watchdog 通信机制；
* Heartbeat 机制；
* 日志 Buffer；
* Crashlog 内容；
* 进程识别机制；
* BDS 紧急关闭机制；
* Backup 执行架构；
* Console 输入显示；
* 中文字符的 Console 编辑行为；
* stdout / stderr 的精确输出顺序；
* 配置文件格式；
* 内部组件之间的通信方式。

尤其是 Console 输入编辑方面，目前并不以成为一个完整的终端模拟器为目标。

例如复杂的中文字符编辑可能存在显示上的边界情况。

[点击返回目录](#目录)

---

## 版本

当前架构相较于最初单纯的 BDS Backup Manager 已经发生了较大的变化。

项目目前已经从：

```text
Backup Manager
```

逐渐发展为：

```text
Maintenance Tool
```

因此目前更适合使用：

```text
v0.5.x
```

这样的早期版本号，而不是直接进入 `v1.0`。

一个未来的 `v1.0` 应至少意味着以下部分已经相对稳定：

* Console；
* BDS Pipe；
* BDS 生命周期管理；
* Backup；
* Watchdog；
* Heartbeat；
* Logging；
* Crashlog；
* Process Identification；
* Configuration；
* Emergency Shutdown。

[点击返回目录](#目录)

---

## 许可证

当前 README 不指定具体的开源许可证。

如果项目未来公开发布并允许其他人自由修改或重新分发，应在仓库中明确加入相应的 License 文件。

[点击返回目录](#目录)

---

## 项目状态

**My BDS MaintenanceTool 是一个面向 Minecraft Bedrock Dedicated Server 的实验性维护与管理工具。**

当前项目的核心思想是：

```text
一个可迁移的工具文件
        +
内部独立的 Console
        +
Backup
        +
Watchdog
        +
日志系统
        +
Crashlog
        +
精确进程识别
        +
BDS stdin/stdout/stderr Pipe
```

在保持部署简单的同时，让工具能够在 BDS 正常运行、备份、重启、主进程异常退出等不同情况下保持尽可能可靠的行为。

**当前状态：`v0.5.x — Experimental Development`**

[点击返回目录](#目录)
