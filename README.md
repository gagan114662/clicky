# ipop.ai

ipop.ai is a macOS menu-bar voice agent. Hold Control+Option, speak a task, and it can open apps, type, click, use approved screen context, or launch background AI agent sessions.

## Download

The beta DMG is distributed from GitHub Releases:

```text
https://github.com/gagan114662/ipop-ai/releases/latest/download/ipop-ai-beta.dmg
```

## Local Development

Requirements:

- macOS 14+
- Xcode 15+
- Apple Developer ID certificate for production signing and notarization
- Optional provider keys for Z.ai, AssemblyAI, ElevenLabs, Anthropic, or local Codex/Claude CLI auth

Open the project:

```bash
open leanring-buddy.xcodeproj
```

In Xcode, select the `leanring-buddy` scheme, choose your signing team, then build and run.

## Runtime Configuration

The app intentionally does not ship provider API secrets in the bundle. Configure local beta keys with `defaults` or environment variables:

```bash
defaults write ai.ipop.mac AIProvider zai
defaults write ai.ipop.mac ZAIAPIKey '<your-zai-api-key>'
defaults write ai.ipop.mac ElevenLabsAPIKey '<your-elevenlabs-api-key>'
```

More provider notes live in:

- `docs/zai-provider.md`
- `docs/elevenlabs-tts.md`
- `docs/macos-voice.md`

## Release

Use the release script after signing, notarization, Sparkle, and GitHub CLI credentials are configured:

```bash
SPARKLE_PUBLIC_ED_KEY='<your-sparkle-public-key>' ./scripts/release.sh
```

The script builds `ipop.ai.app`, creates `ipop-ai-beta.dmg`, notarizes and staples the DMG, generates `appcast.xml`, and publishes the GitHub release.

## Permissions

The app asks for:

- Microphone, for push-to-talk voice capture
- Accessibility, for approved keyboard/mouse actions
- Screen Recording / ScreenCaptureKit, for screen-aware requests
- Apple Events, for opening and controlling apps you explicitly ask it to use
