# AI Usage Bar for macOS

![AI Usage Bar menu bar and popover](docs/usage-popover.svg)

**Languages:** [English](#english) | [繁體中文](#繁體中文)

## English

AI Usage Bar is a small macOS menu bar app that shows your current AI usage at a glance:

- `GPT xx%`: Codex / ChatGPT 5-hour usage
- `Claude xx%`: Claude 5-hour usage from Claude Code statusline data

It is intentionally conservative: no browser scraping, no cookie reading, no Keychain access, no token handling, no telemetry, and no background daemon.

### Install

Download:

[installer/AIUsageBar-macOS-0.1.0.pkg](installer/AIUsageBar-macOS-0.1.0.pkg)

The installer places the app at:

```text
/Applications/AI Usage Bar.app
```

Compatibility:

- macOS 13 Ventura or newer
- Apple Silicon and Intel Macs
- Universal `arm64 + x86_64` app and Claude helper
- Codex desktop app is required for Codex / ChatGPT usage
- Claude Code is required for Claude usage updates

> Note: the public package is currently ad-hoc signed. Without Apple Developer ID signing and notarization, macOS may show an "unidentified developer" warning. The source code is included so the app can be audited and rebuilt locally.

### First Run

Codex usage usually works automatically when the Codex desktop app is installed and logged in.

Claude usage needs one safe setup step:

1. Click **Install / Reinstall Claude statusline bridge** in AI Usage Bar.
2. If needed, click **Claude Code login**. This opens Claude Code's official login flow.
3. Send one message in Claude Code. Claude Code will invoke the statusline bridge and usage will appear.

After setup is complete, the setup controls disappear and the popover switches to the compact usage view.

Claude's timestamp means:

```text
Last updated: HH:mm:ss · Updates after Claude replies
```

Pressing **Refresh** rereads the local cache. It does not force Claude Code to produce a new statusline update.

### How It Works

![Security data flow](docs/security-flow.svg)

#### Codex / ChatGPT

The app starts the local Codex app-server from:

```text
/Applications/Codex.app/Contents/Resources/codex
```

Then it calls the local JSON-RPC method:

```text
account/rateLimits/read
```

Only usage percentages, reset times, plan information, and credit balance are displayed.

#### Claude

Claude usage is read through Claude Code's official statusline integration.

The app installs a native helper at:

```text
~/.claude/usage-bar/statusline-bridge
```

and writes this statusline command to Claude Code settings:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/usage-bar/statusline-bridge",
    "refreshInterval": 10
  }
}
```

When Claude Code receives account status data, it passes statusline JSON to the helper over stdin. The helper extracts only rate-limit percentages and reset timestamps, then writes:

```text
~/.claude/usage-bar/latest.json
```

The menu bar app reads that small cache file.

### Security Model

The app does not:

- read browser cookies
- read Claude Desktop / ChatGPT Desktop private storage
- read macOS Keychain items
- request Accessibility permission
- request Screen Recording permission
- request Full Disk Access
- collect prompts, responses, API keys, or session tokens
- send telemetry to any server

The only user files it writes are:

```text
~/.claude/settings.json
~/.claude/usage-bar/statusline-bridge
~/.claude/usage-bar/latest.json
```

If an existing Claude Code statusline is present, it is backed up to:

```text
~/.claude/usage-bar/previous-statusline.json
```

Read the full security notes in [SECURITY.md](SECURITY.md).

### Build From Source

Requirements:

- macOS 13 or newer
- Xcode Command Line Tools
- Codex desktop app installed for Codex usage
- Claude Code installed for Claude usage

Build the app:

```bash
CodexUsageBar/build.sh
```

Build the installer package:

```bash
scripts/build-installer.sh
```

Run the security audit helper:

```bash
scripts/security-audit.sh
```

The build script produces universal `arm64 + x86_64` binaries by default.

### Limitations

- Claude usage updates only after Claude Code invokes the statusline command.
- If Claude Desktop or Claude Cowork is used without Claude Code activity, the app shows the latest Claude Code statusline snapshot.
- The package is ad-hoc signed unless it is rebuilt with an Apple Developer ID certificate and notarized.
- Future Codex or Claude Code changes may require updates.

## 繁體中文

AI Usage Bar 是一個簡潔的 macOS 選單列小工具，用來快速查看目前 AI 使用量：

- `GPT xx%`：Codex / ChatGPT 5 小時用量
- `Claude xx%`：Claude 5 小時用量，資料來自 Claude Code 官方 statusline

它的設計原則是保守、安全、可審查：不爬瀏覽器、不讀 cookie、不讀 Keychain、不碰 token、不送遙測，也沒有額外背景 daemon。

### 安裝

下載：

[installer/AIUsageBar-macOS-0.1.0.pkg](installer/AIUsageBar-macOS-0.1.0.pkg)

安裝後 app 會放在：

```text
/Applications/AI Usage Bar.app
```

相容性：

- macOS 13 Ventura 或更新版本
- 支援 Apple Silicon 與 Intel Mac
- app 和 Claude helper 都是 universal `arm64 + x86_64`
- Codex / ChatGPT 用量需要已安裝並登入 Codex 桌面版
- Claude 用量更新需要 Claude Code

> 注意：目前公開安裝包是 ad-hoc 簽名，尚未使用 Apple Developer ID 簽名與 notarization。macOS 第一次安裝時可能顯示「未識別開發者」提示。原始碼已放在 repo 內，可自行審查或本機重建。

### 第一次使用

Codex 用量通常在 Codex 桌面版已安裝並登入後會自動顯示。

Claude 需要一個安全設定步驟：

1. 在 AI Usage Bar 裡點 **Install / Reinstall Claude statusline bridge**。
2. 若尚未登入，點 **Claude Code login**，會開啟 Claude Code 官方登入流程。
3. 在 Claude Code 送出一則訊息。Claude Code 回應後會呼叫 statusline bridge，用量就會出現。

設定完成後，設定區會自動隱藏，介面會變成精簡用量模式。

Claude 的時間說明是：

```text
最後更新：HH:mm:ss · Claude 回應後才更新
```

按 **刷新** 只會重新讀取本機快取，不會強制 Claude Code 產生新的 statusline 更新。

### 運作方式

![Security data flow](docs/security-flow.svg)

#### Codex / ChatGPT

app 會啟動本機 Codex app-server：

```text
/Applications/Codex.app/Contents/Resources/codex
```

然後呼叫本機 JSON-RPC 方法：

```text
account/rateLimits/read
```

畫面只顯示使用百分比、重置時間、方案資訊與 credits。

#### Claude

Claude 用量透過 Claude Code 官方 statusline integration 取得。

app 會安裝一個 native helper：

```text
~/.claude/usage-bar/statusline-bridge
```

並把以下 statusline 設定寫入 Claude Code settings：

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/usage-bar/statusline-bridge",
    "refreshInterval": 10
  }
}
```

當 Claude Code 收到帳號狀態資料時，會把 statusline JSON 透過 stdin 傳給 helper。helper 只擷取 rate-limit 百分比與重置時間，然後寫入：

```text
~/.claude/usage-bar/latest.json
```

選單列 app 只讀取這個小型快取檔。

### 安全模型

app 不會：

- 讀取瀏覽器 cookie
- 讀取 Claude Desktop / ChatGPT Desktop 私有儲存
- 讀取 macOS Keychain
- 要求 Accessibility 權限
- 要求 Screen Recording 權限
- 要求 Full Disk Access
- 收集 prompts、responses、API keys 或 session tokens
- 傳送遙測到任何伺服器

它只會寫入以下使用者檔案：

```text
~/.claude/settings.json
~/.claude/usage-bar/statusline-bridge
~/.claude/usage-bar/latest.json
```

如果原本已有 Claude Code statusline，會先備份到：

```text
~/.claude/usage-bar/previous-statusline.json
```

完整安全說明請看 [SECURITY.md](SECURITY.md)。

### 從原始碼建置

需求：

- macOS 13 或更新版本
- Xcode Command Line Tools
- 若要顯示 Codex 用量，需要安裝 Codex 桌面版
- 若要顯示 Claude 用量，需要安裝 Claude Code

建置 app：

```bash
CodexUsageBar/build.sh
```

建置安裝包：

```bash
scripts/build-installer.sh
```

執行安全掃描：

```bash
scripts/security-audit.sh
```

build script 預設會產生 universal `arm64 + x86_64` binary。

### 限制

- Claude 用量只有在 Claude Code 呼叫 statusline command 後才會更新。
- 如果只使用 Claude Desktop 或 Claude Cowork，而沒有 Claude Code 活動，app 會顯示最後一次 Claude Code statusline snapshot。
- 安裝包目前是 ad-hoc 簽名；若要正式公開發佈，建議使用 Apple Developer ID 簽名並 notarize。
- 未來 Codex 或 Claude Code 若改變本機介面，可能需要更新 app。

## License

MIT
