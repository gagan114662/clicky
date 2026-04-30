# ElevenLabs TTS

ipop prefers ElevenLabs for spoken replies when an API key is configured. If no
ElevenLabs key is present, it falls back to the built-in macOS `say` voice.

## Enable Locally

```sh
defaults write ai.ipop.mac ElevenLabsAPIKey '<your-elevenlabs-api-key>'
```

Optional voice/model overrides:

```sh
defaults write ai.ipop.mac ElevenLabsVoiceID '21m00Tcm4TlvDq8ikWAM'
defaults write ai.ipop.mac ElevenLabsModelID 'eleven_flash_v2_5'
```

## Environment Overrides

```sh
IPOP_ELEVENLABS_API_KEY='<your-elevenlabs-api-key>' \
IPOP_ELEVENLABS_VOICE_ID='21m00Tcm4TlvDq8ikWAM' \
open /Applications/ipop.ai.app
```

Supported env vars:

- `IPOP_ELEVENLABS_API_KEY`
- `IPOP_ELEVENLABS_VOICE_ID`
- `IPOP_ELEVENLABS_MODEL_ID`

## Fallback

If ElevenLabs is missing, rate-limited, or returns an error, ipop logs the error
and speaks the same text through the macOS voice fallback.
