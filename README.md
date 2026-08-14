作者自述：
发行就是V1.6，因为前几个版本是在我的openclaw上迭代的，用的deepseek，然后minimax在旁简单协助了一下，本人只是个小白，来此开个号玩玩，随手做的小工具只是作为好玩儿和分享，第一次发布东西，如果有什么问题还请指出，感谢
# 便签 StickyNotes 🍊

一个 Win7 风格、绿色免安装的 Windows 桌面便签小工具。纯 PowerShell + WPF 实现，单文件脚本，无需任何依赖，无需exe。

![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE) ![License](https://img.shields.io/badge/License-MIT-green)

## ✨ 功能

- **多开便签**：双击一次新建一张，可同时开多张
- **自动保存**：输入防抖 1.5s + 30s 兜底，永不丢字；位置/颜色/大小全记忆
- **删除线**：选中文字右键一键划线（再点取消），适合勾待办 ✅
- **6 色切换**：黄 / 绿 / 蓝 / 粉 / 紫 / 橙
- **历史窗口**：列出所有有文字的便签，双击打开旧便签
- **标题重命名**：点标题直接改名（txt 同步改名）
- **空签自清**：关掉没写字的便签自动进回收站，不留垃圾
- **置顶显示** / 全部关闭 / 自动滚动备份

## 🚀 快速开始

```
git clone https://github.com/<你的用户名>/sticky-notes.git
```

然后**双击 `新建便签.bat`** 即可（Windows 10/11 自带 PowerShell，无需安装任何东西）。

## ⌨️ 快捷键

| 快捷键 | 功能 |
|---|---|
| `Ctrl+S` | 保存（标题闪「已保存 ✓」） |
| `Ctrl+N` | 新建便签 |
| `Ctrl+W` | 关闭当前便签 |
| `Ctrl+H` | 打开历史列表 |
| 点标题栏 | 重命名（回车确认 / Esc 取消） |

## 🖱️ 右键菜单

新建便签 · 保存 · **删除线** · 置顶显示 · 颜色 · 查看历史 · 打开数据文件夹 · 关闭便签 · 全部关闭

## 💾 数据存储

- 内容：`%APPDATA%\StickyNotes\` 下的 `.txt`（**纯文本**，记事本直接可读）
- 位置/颜色：同名 `.pos` 文件
- 删除整个 `StickyNotes` 文件夹 = 彻底卸载
- 环境变量 `STICKYNOTE_DATA_DIR` 可覆盖数据目录（便携/测试用）

> 删除线以 `~~文字~~` 标记存入纯文本，兼容任何文本编辑器。

## 🛠️ 技术栈

- **PowerShell 5.1** — 全部业务逻辑
- **WPF / XAML** — 无边框置顶窗口 UI
- **Win32 API**（内嵌 C#）— EnumWindows / PostMessage 等底层调用

## 📁 文件结构

```
sticky-notes/
├── 便签.ps1          # 主程序（单文件）
├── 新建便签.bat      # 启动器（双击新建便签）
├── 使用说明.txt      # 用户手册
└── 更新日志.md       # 版本历史
```

## 📜 License

[MIT](LICENSE)
