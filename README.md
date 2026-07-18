# Reset! for macOS

SwiftUI 菜单栏额度监控工具，支持 Codex（ChatGPT）、Claude Code、Google Antigravity、Cursor 的 5 小时 / 周限额，以及 Telegram 通知与 iCloud 多设备推送协调。

**仓库：** [github.com/EEliberto/Reset-macOS](https://github.com/EEliberto/Reset-macOS)

## 功能

- 菜单栏常驻界面与设置窗口
- 本机额度读取（不跨设备复制额度状态）
- Telegram Bot：`/quota`、`/refresh`，配置需“确认并测试推送”
- iCloud：Telegram 配置、推送设备选举、用量历史样本
- **Sparkle** 自动更新（GitHub Releases + `appcast.xml`）

## 打开

```sh
xcodegen generate
open Reset!.xcodeproj
```

选择 **Reset** scheme 后运行。

## 版本与发布

当前版本写在 `project.yml` 的 `MARKETING_VERSION`。打 Release / 生成 appcast / 上传 DMG：

```sh
./scripts/release.sh 270718
```

然后将更新后的 `appcast.xml` 提交到 `main`。应用会通过 Sparkle 读取：

`https://raw.githubusercontent.com/EEliberto/Reset-macOS/main/appcast.xml`

## 第三方致谢

见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。含 [Sparkle](https://sparkle-project.org/)（MIT）。
