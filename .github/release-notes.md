## 安装 / Install

1. 下载下方的 `SelectTranslate-*.zip`，解压后把 **SelectTranslate.app** 拖到「应用程序」文件夹。
2. 应用未经 Apple 公证，首次打开前在终端执行：
   ```bash
   xattr -dr com.apple.quarantine /Applications/SelectTranslate.app
   ```
   或在 Finder 中右键 → 打开。
3. 按提示授予「辅助功能」权限（用于读取选中的文字）。
4. 点击菜单栏图标 → 设置…，选择 Codex / Claude Code / OpenAI 兼容 API / Anthropic API。

Download `SelectTranslate-*.zip`, move the app to /Applications, run
`xattr -dr com.apple.quarantine /Applications/SelectTranslate.app` (the app is not notarized),
then grant Accessibility permission and pick a provider in Settings.

通用二进制，支持 Apple Silicon 与 Intel，macOS 13+。
