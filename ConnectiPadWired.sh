#!/bin/bash

# ================= 配置区域 =================
# 你的 SidecarLauncher 绝对路径 (请确保路径无误)
LAUNCHER="/Users/user1/github.com/SidecarLauncher/SidecarLauncher/SidecarLauncher"

# ================= 执行区域 =================

# 方案 A：盲连模式 (推荐)
# 不带设备名，程序会自动寻找任何插了 USB 线的 Sidecar 设备
# 适合：无头 Mac mini，即插即用，不需要改名字
"$LAUNCHER" connect

# 方案 B：指定模式 (备选)
# 如果你只想连特定设备，请把上面那行注释掉，用下面这行：
# "$LAUNCHER" connect "yours iPad"

# ===========================================
# 脚本执行完毕后，如果是 .command 文件运行的，
# 你可以在终端设置里改为“当 Shell 退出时关闭窗口”，
# 这样连接成功后黑框就会自动消失。
