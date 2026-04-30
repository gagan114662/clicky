# ElevenLabs TTS

ipop prefers ElevenLabs for spoken replies when an API key is configured. If no
ElevenLabs key is present, it falls back to the built-in macOS `say` voice.

## Enable Locally

```sh
defaults write com.yourcompany.leanring-buddy ClickyElevenLabsAPIKey '<your-elevenlabs-api-key>'
```

Optional voice/model overrides:

```sh
defaults write com.yourcompany.leanring-buddy ClickyElevenLabsVoiceID '21m00Tcm4TlvDq8ikWAM'
defaults write com.yourcompany.leanring-buddy ClickyElevenLabsModelID 'eleven_flash_v2_5'
```

## Environment Overrides

```sh
CLICKY_ELEVENLABS_API_KEY='<your-elevenlabs-api-key>' \
CLICKY_ELEVENLABS_VOICE_ID='21m00Tcm4TlvDq8ikWAM' \
open /path/to/Clicky.app
```

Supported env vars:

- `CLICKY_ELEVENLABS_API_KEY`
- `CLICKY_ELEVENLABS_VOICE_ID`
- `CLICKY_ELEVENLABS_MODEL_ID`

## Fallback

If ElevenLabs is missing, rate-limited, or returns an error, ipop logs the error
and speaks the same text through the macOS voice fallback.
