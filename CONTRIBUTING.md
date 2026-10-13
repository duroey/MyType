# Contributing to MyType

English · [中文](#中文说明)

This repository is the MyType fork of Type4Me. Contributions must preserve MyType's desktop Agent features, current recognition choices, application identity, and credential/data boundaries. Upstream changes are integrated with focused verification, not by replacing the fork with an upstream package.

- Docs index (current specs vs. archive): [`docs/README.md`](docs/README.md)
- Architecture & development guide: [`AGENTS.md`](AGENTS.md)
- User guides: [`docs/usage/`](docs/usage/)

If you're an AI agent (Claude Code, Codex, Cursor, …) asked to build, deploy or contribute to MyType, start with the fork-specific instructions below.

## Read these files first

1. `AGENTS.md` - full architecture guide, credential storage, key files, development patterns, and how to add new ASR/LLM providers
2. `Package.swift` - Swift Package Manager dependencies and build targets
3. `scripts/deploy.sh` - the build & deploy pipeline (calls `scripts/package-app.sh`)

## Prerequisites

- macOS 14.0+ (Sonoma)
- Xcode Command Line Tools: `xcode-select --install`
- Python 3.12: `brew install python@3.12` (for local ASR servers)
- CMake: `brew install cmake` (only if building SherpaOnnx punctuation engine)

## Build & deploy

```bash
# 1. Clone
git clone https://github.com/duroey/MyType.git && cd MyType

# 2. (Optional) Build SherpaOnnx punctuation engine (~5 min, needs cmake)
bash scripts/build-sherpa.sh

# 3. (Optional) Setup Qwen3-ASR server (needs python3.12, Apple Silicon only)
cd qwen3-asr-server && python3.12 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt && cd ..

# 4. Build a MyType candidate without overwriting the installed app
APP_FLAVOR=mytype VARIANT=cloud ARCH=universal \
APP_PATH="$PWD/dist/MyType.app" \
bash scripts/package-app.sh
```

Steps 2-3 are optional. Skipping them disables local ASR, but cloud ASR works fine.

The normal MyType identity is `MyType.app`, `com.mytype.app`, and `mytype://`.
`VARIANT=cloud` is the value accepted by `package-app.sh` for the cloud-only app;
the upstream DMG workflow calls its corresponding distribution variant `pure`.
Keep the installed app's signing identity and designated requirement when updating
an existing installation. Supply `CODESIGN_IDENTITY` explicitly when necessary.
Do not bundle credentials into distributable packages.

Agent session search also needs the existing AgentsView backend and license.
Pass both `AGENTSVIEW_BINARY` and `AGENTSVIEW_LICENSE` to `package-app.sh`; reuse
the verified versions from the installed MyType app when preparing its update.
Otherwise a newly packaged app may lack the backend used by the experience build.

Before replacing `/Applications/MyType.app`, finish the relevant verification,
verify the candidate signature, and back up the installed app. Preserve the
existing MyType settings, history, index, and current recognition provider/mode.
The retained `scripts/deploy.sh` targets MyType; it must not be run merely to
preview a candidate. `scripts/dev-run.sh` is the retained upstream Type4Me Dev
workflow, not the default MyType experience-update path.

## Code signing & permissions

The following setup applies when explicitly using the separate upstream Dev
workflow. Stable development signing is required to preserve Keychain, Accessibility, and
Microphone permissions across rebuilds. Complete this one-time setup before the
first Dev deploy:

1. Install and open the full Xcode application. Xcode Command Line Tools alone
   cannot configure the signing account.
2. Open **Xcode > Settings > Accounts**, click **+**, choose **Apple Account**,
   and sign in. A paid Apple Developer membership is not required; Xcode can use
   the account's **Personal Team** for local development signing.
3. Select the account and confirm that a Team is listed. You may create the
   certificate manually through **Manage Certificates... > + > Apple
   Development**, or let the repository setup script request it from Xcode:

   ```bash
   bash scripts/setup-dev-signing.sh
   ```

4. Confirm that macOS Keychain contains a valid signing identity:

   ```bash
   security find-identity -v -p codesigning
   ```

   The output must include an `Apple Development: ...` identity. If multiple
   Xcode teams are configured, select one explicitly:

   ```bash
   DEVELOPMENT_TEAM=<team-id> bash scripts/setup-dev-signing.sh
   ```

5. Build and install the development app:

   ```bash
   bash scripts/dev-run.sh
   ```

`dev-run.sh` uses `/Applications/Type4Me Dev.app` and the dedicated
`com.type4me.dev` bundle ID. On the first signed deploy it may ask once for the
Login Keychain password to migrate existing Type4Me credential access from
changing binary hashes to the stable Apple Team ID. The password is held in
memory only and is never stored.

After first launch, grant Microphone and Accessibility access to **Type4Me Dev**
once in **System Settings > Privacy & Security**. Subsequent Dev builds reuse the
same Apple identity, Team ID, bundle ID, and install path, so these permissions
remain valid.

> Here, "development/self signing" means an Xcode-managed **Apple Development**
> certificate associated with the developer's Apple Account. It is not ad-hoc
> signing (`-`). Dev deploys intentionally fail when no stable identity is
> available. `ALLOW_ADHOC_SIGNING=1 bash scripts/dev-run.sh` is an emergency-only
> fallback and may cause macOS to request permissions again after every rebuild.

For non-Dev packaging, a signing identity can be supplied explicitly with
`CODESIGN_IDENTITY="Your Cert" bash scripts/deploy.sh`.

## Key architecture points

- **Swift Package Manager** project, no `.xcodeproj` needed
- **Local ASR**: native SenseVoice provides streaming partial results; the optional Qwen3-ASR Python WebSocket service provides final calibration via MLX/Metal and is managed by `SenseVoiceServerManager`.
- **Cloud ASR**: 15 providers implemented, including Microsoft Azure MAI. StepFun, Bailian, Gemini, ElevenLabs, Grok, and Azure expose streaming/batch choices within one provider. Existing selections are preserved when importing upstream updates.
- **Credentials**: API keys live in the macOS Keychain under `com.mytype.grouped` / `com.mytype.scalar`; non-secret provider settings live in `~/Library/Application Support/mytype/credentials.json` (mode 0600). Legacy Type4Me stores are migration sources, not the active profile. Never put credentials in code or environment variables — GUI apps cannot read shell env vars from `~/.zshrc`.
- **ASR provider architecture**: plugin-based. To add a new provider: implement `ASRProviderConfig` + `SpeechRecognizer` protocol, register in `ASRProviderRegistry.all`. See `AGENTS.md` for details
- **Audio format**: 16kHz mono PCM16-LE, 200ms chunks (6400 bytes)
- **Text injection**: clipboard-based Cmd+V paste with save/restore

## Architecture overview

| Module | Description |
|--------|-------------|
| `Type4Me/ASR/` | ASR engine abstraction layer, pluggable provider architecture |
| `Type4Me/Audio/` | Audio capture (16kHz mono PCM) |
| `Type4Me/Session/` | Core state machine: record > ASR > inject |
| `Type4Me/Services/` | Credential storage, hotwords, model management, Python service management |
| `Type4Me/LLM/` | LLM text processing (15 providers) |
| `Type4Me/Input/` | Global hotkey management |
| `Type4Me/Injection/` | Text injection (clipboard Cmd+V) |
| `Type4Me/Bridge/` | SherpaOnnx C API Swift bridge (optional) |
| `Type4Me/UI/` | SwiftUI interface: floating window + settings |
| `Type4MeIntelliSenseCore/` | Intelli Sense context awareness and preference learning core |
| `Type4MeReviseCore/` | Voice Revise tracking, slot targeting, and replacement core |
| `qwen3-asr-server/` | Python Qwen3-ASR calibration service (Apple Silicon, MLX) |

The ASR provider architecture is fully pluggable: implement `ASRProviderConfig` (define credential fields) and `SpeechRecognizer` (implement recognition logic), register with `ASRProviderRegistry`, and you have a new engine.

---

## 中文说明

本仓库是 MyType fork。接入上游时保留 MyType 的 Agent 会话检索、交接、消息队列和当前识别设置；确认相关行为后再集成。

- 文档入口：[`docs/README.md`](docs/README.md)（区分当前有效文档与历史归档）
- 从源码打包：按上方 *Build & deploy* 使用 `APP_FLAVOR=mytype`、`VARIANT=cloud` 和 `ARCH=universal` 创建候选包；保留已安装版本的稳定签名。需要 Agent 检索时，显式带上已验证的 AgentsView 后端和许可证。
- 体验版更新：备份后替换 `/Applications/MyType.app`，保留 `com.mytype.app`、`mytype://` 和 `~/Library/Application Support/mytype/`。先验证候选包，不把上游 Type4Me 下载包或 Dev 包当作体验版更新。
- 想让 AI Agent 帮你部署：把仓库链接和本文件交给它即可
