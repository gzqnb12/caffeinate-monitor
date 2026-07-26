# Caffeinate 管理器

一个原生 macOS SwiftUI 小工具，用来查看：

- 当前正在运行的 `caffeinate` 进程，以及 PID、运行时间和防休眠参数。
- 已配置但当前未运行的 launchd caffeinate 任务。
- `pmset` 管理的重复自动唤醒计划和 macOS 一次性电源事件。

当前用户 `~/Library/LaunchAgents` 中的任务可以在界面里立即运行、停用、重新启用，
或在二次确认后移到废纸篓。系统级任务只读。完整命令只在内存中显示，常见 token、
密码和 API Key 会自动脱敏。

系统要求：

- macOS 13 Ventura 或更高版本。
- Apple Silicon 或 Intel Mac（构建脚本会自动使用当前 Mac 的架构）。
- 构建源码时需要 Xcode Command Line Tools。

## 构建

无需 Xcode 和第三方依赖：

```sh
./scripts/build_app.sh
```

构建结果：

```text
dist/Caffeinate 管理器.app
```

运行脱敏规则测试：

```sh
./scripts/test.sh
```

## 安装

```sh
./scripts/install_app.sh
```

应用会安装到：

```text
~/Applications/Caffeinate 管理器.app
```

应用使用本机 ad-hoc 签名，适合在当前 Mac 上运行。它没有启用 App Sandbox，
以便读取命令行进程与 LaunchAgent；不需要辅助功能权限，也不会自行启动
`caffeinate`。

## 隐私

应用完全在本机运行，不包含网络请求、遥测或自动更新代码。它不会把进程列表、
命令参数或 launchd 配置写入磁盘；界面和剪贴板中的命令会对常见命令行参数、
环境变量和 URL 中的 Token、密码、API Key 与 Authorization 值进行脱敏。无法
可靠识别的无标签位置参数仍可能原样显示。

## 安全说明

- “停止防休眠”只终止 `caffeinate` 本身，包裹的工作进程不一定同时停止。
- “停用任务”会保留 plist、脚本和历史数据，可以恢复。
- “移到废纸篓”只适用于当前用户的 LaunchAgent plist，并且会先停用任务。
- 自动唤醒计划不是 caffeinate。界面只提供查看和复制取消命令，因为
  `pmset repeat cancel` 会取消整台 Mac 的全部重复电源计划。
