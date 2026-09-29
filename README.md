<div align="center">
  <br>
  <img src="https://github.com/user-attachments/assets/afd6fcf6-b022-40ab-84b3-720bb6206b85" width="136" alt="Reset! 图标">
  <h1>Reset!</h1>
  <h3>在 Mac 菜单栏实时查看 AI 智能体用量</h3>
  <p>集中查看常用 AI 智能体的剩余用量、重置时间和当前状态。</p>
  <br>
  <p>
    <a href="https://github.com/EEliberto/Reset-macOS/releases/latest"><strong>下载 Reset!</strong></a>
    &nbsp;&nbsp;·&nbsp;&nbsp;
    <a href="RELEASE_NOTES_260926.md">查看新功能</a>
  </p>
  <p><sub>需要 macOS 26 或更高版本。</sub></p>
  <br>
</div>

<p align="center">
  <img src="https://github.com/user-attachments/assets/135b0a80-5f1a-4fec-9dbf-38b009468cd3" alt="Reset! 主窗口" width="460">
</p>

<br>

## 用量状态，随时可见

Reset! 常驻于 Mac 菜单栏，以简洁的圆环显示当前 AI 智能体的剩余用量。打开主窗口，即可查看各项用量限额、重置时间和服务状态，无需在多个 App 与网页之间切换。

## 自动显示正在使用的服务

当你在不同的 AI 智能体之间切换时，菜单栏图标会自动显示当前服务的用量。你也可以在设置中选择要显示的智能体，让 Reset! 只保留与你有关的信息。

目前支持：

- Codex（ChatGPT）
- Claude Code
- Cursor
- Google Antigravity 与 Antigravity IDE
- Kimi
- Grok CLI 本地状态

## 信息留在这台 Mac 上

Reset! 直接读取各项服务在这台 Mac 上的登录状态和用量信息。数据不会发送到 Reset! 的服务器，也不依赖额外账户或云端协调服务。

## 在合适的时间提醒你

你可以为低用量和额度重置启用本机通知。Reset! 会按照你的设置发送提醒，也可以完全关闭通知。

## 开始使用

1. 下载最新的 [Reset! DMG](https://github.com/EEliberto/Reset-macOS/releases/latest)。
2. 打开磁盘映像，并将 Reset! 拖移到“应用程序”文件夹。
3. 打开 Reset!，然后从菜单栏选择需要显示的 AI 智能体。

如果 Mac 阻止首次打开，请前往“系统设置”>“隐私与安全性”，在安全性提示中选择“仍要打开”。

## 自动更新

Reset! 会定期检查新版本。你也可以打开“关于 Reset!”，随时检查更新。自动更新由 [Sparkle](https://sparkle-project.org/) 提供支持。

## 从源码构建

项目使用 SwiftUI 和 Swift 6 构建。使用 Xcode 打开 `Reset!.xcodeproj`，然后运行 `Reset` 方案。

<br>

<div align="center">
  <p><a href="https://github.com/EEliberto/Reset-macOS/issues">报告问题</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="THIRD_PARTY_NOTICES.md">第三方软件声明</a></p>
  <sub>Reset! 与文中提及的 AI 服务及其开发者无隶属关系。相关名称和商标归各自所有者所有。</sub>
</div>
