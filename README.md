# Reset! for macOS

<p align="center">
  <img src="https://github.com/user-attachments/assets/afd6fcf6-b022-40ab-84b3-720bb6206b85" alt="Reset!" width="180" />
</p>

<p align="center">
  <strong>你的 AI Agent 额度一览</strong><br />
  一眼看清 Codex · Claude Code · Antigravity · Cursor 还剩多少额度
</p>

<p align="center">
  <a href="https://github.com/EEliberto/Reset-macOS/releases/latest"><img src="https://img.shields.io/github/v/release/EEliberto/Reset-macOS?style=flat-square&label=Download" alt="Download" /></a>
  <a href="https://github.com/EEliberto/Reset-macOS/releases"><img src="https://img.shields.io/github/downloads/EEliberto/Reset-macOS/total?style=flat-square" alt="Downloads" /></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?style=flat-square" alt="macOS" />
  <img src="https://img.shields.io/badge/SwiftUI-native-orange?style=flat-square" alt="SwiftUI" />
</p>

---

SwiftUI 原生菜单栏工具，监控 **Codex（ChatGPT）**、**Claude Code**、**Google Antigravity**、**Cursor** 的 5 小时 / 周限额，并支持 **Telegram 推送** 与 **iCloud 多设备协调**。

## 功能

| | |
|---|---|
| **菜单栏常驻** | 设置窗口 + 圆环进度，当前 Agent 自动切换 |
| **本机额度** | 直接读取本机登录态，不跨设备复制额度 |
| **Telegram Bot** | 额度更新 / 重置第一时间推送到手机 |
| **iCloud 协调** | 多台 Mac 只选一台负责推送，避免重复通知 |
| **Sparkle 更新** | 关于页一键检查，GitHub Release 自动更新 |

## 主页面

实时查看各 AI Agent 额度；菜单栏圆环会随你正在使用的 Agent **自动切换**。

<p align="center">
  <img src="https://github.com/user-attachments/assets/135b0a80-5f1a-4fec-9dbf-38b009468cd3" alt="主页面" width="420" />
</p>

## Telegram Bot

自建 Bot 后，额度更新与重置会推送到 Telegram，出门也能盯着。

<p align="center">
  <img src="https://github.com/user-attachments/assets/5c92b59f-2e69-4f27-8e33-2d647de63cb6" alt="Telegram 设置" width="520" />
  &nbsp;
  <img src="https://github.com/user-attachments/assets/e45e3067-118d-454c-a398-b0b118b53cba" alt="Telegram 推送" width="260" />
</p>

配置步骤很简单：填入 Bot Token 与 Chat ID，点 **“确认并测试推送”**，收到测试消息即表示成功。

### 推荐 Bot 头像

<p align="center">
  <img src="https://github.com/user-attachments/assets/1a9302a4-6010-4ec8-a2f8-4565ff25ae6c" alt="Telegram 头像" width="160" />
</p>

## 安装

1. 打开 [Releases](https://github.com/EEliberto/Reset-macOS/releases/latest)
2. 下载 **`Reset-270718.dmg`**
3. 将 **Reset!** 拖入 Applications

首次打开若提示未验证开发者：系统设置 → 隐私与安全性 → 仍要打开。

## 致谢

见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。自动更新基于 [Sparkle](https://sparkle-project.org/)。
