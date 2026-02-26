# 🚀 SideLinker (Advanced) - 无头 Mac mini 的 iPad 随航终极方案

[English](./README.md) | **简体中文**

> **专为 Headless Mac mini / Mac Studio 用户打造。**
> 「挎斗之桥」：基于 `SidecarCore` 私有框架，实现 iPad 有线/无线自动重连、盲连（自动识别）及系统原生通知反馈。

---

## 🌟 为什么选择这个版本？

相较于传统的 AppleScript 脚本或早期 Sidecar 启动器，本项目针对 **M4 Mac mini** 等无头主机进行了深度优化：

* **🔌 独家“盲连模式”**：无需在脚本中指定 iPad 名称，程序会自动扫描并强制连接插线设备。
* **🔄 智能重试机制**：内置 10 次重试逻辑，解决开机时系统服务加载慢的问题。
* **⚖️ 双模自动切换**：优先通过 **有线直连 (`-wired`)** 以确保 0 延时，失败后自动转为无线。
* **🚀 权限地狱终结者**：通过 Automator App 封装，完美避开 SSH 远程调用时的 `Operation not permitted` 报错。

---

## 🖥️ 第一步：前置准备 - 配置虚拟屏幕 (BetterDisplay)

> **⚠️ 极重要：此步骤必须在连接【物理显示器】的情况下完成。**
> 否则 Mac 拔掉 HDMI 后 GPU 可能会停止输出，导致 Sidecar 闪退。

我们需要使用 **BetterDisplay** 创建一个虚拟主显示器。

1.  **下载**：[BetterDisplay 官方 Release](https://github.com/waydabber/BetterDisplay/releases)。
2.  **创建虚拟屏**：在菜单中选择 `新建虚拟屏幕`。
<img width="596" height="1294" alt="image" src="https://github.com/user-attachments/assets/62bacbbf-cd96-4835-9bd6-af223d5066d4" />
<img width="1792" height="690" alt="image" src="https://github.com/user-attachments/assets/40b0a965-5606-43b7-ad35-ccbc5aeeb8fc" />
3.  **虚拟屏默认设置为镜像**：如果没有任何显示器，iPad 连接后会自动变为主显示器
<img width="968" height="884" alt="image" src="https://github.com/user-attachments/assets/ee3c8666-effb-49fb-a3b6-63ec9d116e28" />
3.  **核心配置**：
    * 允许 **"登录时打开"**。
    * **“隐私与安全性”** 开启 **“辅助功能”**
    * 打开 **设置-通用-共享-远程登录**
<img width="492" height="151" alt="image" src="https://github.com/user-attachments/assets/9e14bf08-67fd-478b-ab71-c32225404bb5" />

---

## 🛠️ 第二步：安装脚本

本项目提供编译好的二进制文件。

1.  **下载**：从 Release 页面下载 `SidecarLauncher`。
2.  或者**手动编译**：
    ```bash
    swiftc main.swift -o SidecarLauncher
    ```

---

## 📦 第三步：封装为 App (核心权限修复)

1.  打开 **自动操作 (Automator)** -> 新建 **应用程序 (Application)**。
2.  添加 **运行 Shell 脚本**：
    ```bash
    /你的路径/SidecarLauncher connect
    ```
3.  保存为 `ConnectiPadWired.app` 并放入 `/Applications`。

---

## 📱 第四步：iPad 快捷指令配置

1. 在 iPad 上创建快捷指令：
   * **操作**：通过 SSH 运行脚本
   * **脚本**：`open -a ConnectiPadWired`
2. 或者直接执行项目中的 `Sidecar Launcher.shortcut`，安装快捷指令，之后会自动同步到 iPad。
3. 填写关键信息：主机、用户名和密码。主机名在**设置-通用-共享-本地主机名**查看，用户名和密码是登录 mac mini 时使用的用户名和密码。

<img width="790" height="557" alt="image" src="https://github.com/user-attachments/assets/02585e98-6778-424b-9be9-5f6302fca40a" />


---

## 🔌 进阶玩法：无网直连

无需 USB 线连接 iPad 与 Mac，只要在同一局域网，并打开蓝牙，在 iPad 上直接运行快捷指令。由于开启了“盲连模式”，脚本会自动识别无线链路并瞬间点亮屏幕。
