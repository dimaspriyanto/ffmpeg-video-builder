# FFmpeg Ruby Video Builder

A small Ruby executable for generating vertical short videos with FFmpeg.

It is designed for icon-based videos, captions, simple transitions, voiceovers, and repeatable content production workflows.

## Features

- Ruby-only command generator
- JSON project configuration
- Vertical video output, default `1080x1920`
- Solid color, image, or video background
- Icon/image overlays
- Text captions
- Audio waveform overlays
- Rectangle overlays for panels/highlights
- Basic animations:
  - `fade`
  - `pop`
  - `slide_left`
  - `slide_right`
  - `slide_up`
  - `slide_down`
- Optional audio/voiceover
- Dry-run mode to inspect the generated FFmpeg command

## Requirements

- Ruby 3.0+
- FFmpeg installed and available in your terminal PATH
- Optional: local Kokoro Python environment for narration audio generation
- Optional: local `openai/whisper` CLI for audio transcription

Check FFmpeg:

```bash
ffmpeg -version
```

Check local Whisper:

```bash
whisper --help
```

If Whisper is installed but not on `PATH`, set `WHISPER_COMMAND` to the full
path of the executable.

Kokoro installation is intentionally not handled by this bundle. The local
helper script lives at `bin/kokoro-tts`; set `KOKORO_PYTHON` if Kokoro is
installed in a specific Python or virtualenv.

Kokoro remains the default narration engine. Google AI TTS can be enabled from
workspace config or with `--tts-engine google_ai`.

## Usage

From the repository root:

```bash
chmod +x bin/ffmpeg_video_builder
bin/ffmpeg_video_builder script.txt
```

Dry-run only:

```bash
bin/ffmpeg_video_builder --dry-run script.txt
```

## Workflow modes

| Mode | Single script | Workspace bulk |
|---|---|---|
| Prepare project assets only | `bin/ffmpeg_video_builder --until-icons script.txt` | `bin/ffmpeg_video_builder --bulk-workspace workspace --until-icons` |
| Prepare assets and render video | `bin/ffmpeg_video_builder script.txt` | `bin/ffmpeg_video_builder --bulk-workspace workspace` |
| Regenerate after editing icons | `bin/ffmpeg_video_builder --rebuild-project projects/Project_1_02062026` | `bin/ffmpeg_video_builder --rebuild-workspace workspace` |

Create the project structure, narration, subtitles, downloaded icons, icon plan,
and generated FFmpeg config without rendering the MP4:

```bash
bin/ffmpeg_video_builder --prepare-only script.txt
bin/ffmpeg_video_builder --until-icons script.txt
```

Generate multiple videos from one workspace:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace
```

Prepare every script in a workspace without rendering the videos:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace --prepare-only
bin/ffmpeg_video_builder --bulk-workspace workspace --until-icons
```

By default, the bulk command reads `workspace/scripts.txt`. Put repeated script
blocks in that file:

```text
Title: First Video
Category: Financial Advice

Content:
First video script text.

Title: Second Video
Category: Financial Advice

Content:
Second video script text.
```

Workspace generation also reads `workspace/config.json` when it exists. Values
in that file override built-in defaults, and command-line flags override
`config.json`.

```json
{
  "video": {
    "width": 1080,
    "height": 1920,
    "fps": 30
  },
  "background": {
    "type": "image",
    "path": "background.png"
  },
  "icon": {
    "source_url": "https://icon-sets.iconify.design/noto-v1",
    "style": "regular",
    "license_type": "permissive",
    "size": 512,
    "candidate_limit": 8
  },
  "pipeline": {
    "waveform": true,
    "icon_width": 320
  },
  "kokoro": {
    "voice": "af_heart",
    "speed": 1.0,
    "lang_code": "a"
  },
  "whisper": {
    "model": "base",
    "task": "transcribe",
    "word_timestamps": true
  }
}
```

To use Google AI TTS for a workspace, add a `google_ai_tts` block. Its presence
selects Google AI TTS instead of Kokoro:

```json
{
  "google_ai_tts": {
    "model": "gemini-3.1-flash-tts-preview",
    "voice": "Zephyr",
    "style": "Scene: Sincere calm night. Speaker style: Empathetic."
  }
}
```

If neither `google_ai_tts` nor `tts.engine` is configured, Kokoro is used.
The engine can also be selected explicitly with `--tts-engine kokoro` or
`--tts-engine google_ai`; CLI flags override `workspace/config.json`.

If the workspace contains one background media file, or a file named
`background.png`, `background.jpg`, `background.mp4`, and so on, that media is
used as the background for every generated video. If no background media exists,
the default solid `#FFC067` background is used. You can also set the background
explicitly:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace --background-color "#FFC067"
bin/ffmpeg_video_builder --bulk-workspace workspace --background-image workspace/background.png
bin/ffmpeg_video_builder --bulk-workspace workspace --background-video workspace/background.mp4
bin/ffmpeg_video_builder --bulk-workspace workspace --background-image "https://example.com/background.jpg"
```

The bulk command writes a `bulk_manifest.json` file into the workspace with the
generated project paths and output video files.

After editing the `icon_plan.json` files in projects created from a workspace,
regenerate every project listed in `workspace/bulk_manifest.json`:

```bash
bin/ffmpeg_video_builder --rebuild-workspace workspace
```

To refresh icon downloads and configs for every listed project without rendering
MP4 files, combine it with `--until-icons`:

```bash
bin/ffmpeg_video_builder --rebuild-workspace workspace --until-icons
```

The main input is a text script. The full pipeline:

1. Generate narration audio with Kokoro or Google AI TTS.
2. Generate sentence timings and subtitles with local Whisper.
3. Choose an icon keyword for each sentence.
4. Search and download icons from Iconify.
5. Generate a project config and render the video with FFmpeg.

Generated assets are written into `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/`, including
`script_input.txt`, `audio_voiceover.wav`, `subtitle_sentences.json`, `subtitle_sentences.srt`,
`icon_plan.json`, `config_project.json`, and `DDMMYYYY_TitleOfTheVideo.mp4`.

After a video render completes successfully, the final MP4 is moved into
`outputs/`. The project's `pipeline_metadata.json` is updated with the moved
output path. For bulk workspace runs, `workspace/bulk_manifest.json` is also
updated with the moved output paths.

For example, the first project created on June 2, 2026 is written to
`projects/Project_1_02062026/`, and a script titled `My Video Title` renders to
`outputs/02062026_MyVideoTitle.mp4`.

## Google Drive upload

Rendered files can be uploaded to Google Drive after generation. Use either an
OAuth access token:

```bash
GOOGLE_DRIVE_ACCESS_TOKEN="ya29..." \
  bin/ffmpeg_video_builder --google-drive-upload outputs/02062026_MyVideoTitle.mp4
```

Or use a service account JSON file:

```bash
bin/ffmpeg_video_builder \
  --google-drive-credentials config/google-service-account.json \
  --google-drive-folder-id "DRIVE_FOLDER_ID" \
  --google-drive-upload outputs/02062026_MyVideoTitle.mp4
```

To upload every output listed in a workspace `bulk_manifest.json`:

```bash
bin/ffmpeg_video_builder \
  --google-drive-credentials config/google-service-account.json \
  --google-drive-folder-id "DRIVE_FOLDER_ID" \
  --google-drive-upload-workspace workspace
```

## Facebook upload

Rendered MP4 files can be uploaded to a Facebook Page through the Graph Video
endpoint. Provide a Page ID and Page access token:

```bash
FACEBOOK_PAGE_ID="123456789" \
FACEBOOK_ACCESS_TOKEN="EAAB..." \
  bin/ffmpeg_video_builder --facebook-upload outputs/02062026_MyVideoTitle.mp4
```

Upload every output listed in a workspace manifest:

```bash
bin/ffmpeg_video_builder \
  --facebook-page-id "123456789" \
  --facebook-access-token "EAAB..." \
  --facebook-upload-workspace workspace
```

Optional post metadata:

```bash
bin/ffmpeg_video_builder \
  --facebook-upload outputs/02062026_MyVideoTitle.mp4 \
  --facebook-title "Video title" \
  --facebook-description "Video description" \
  --facebook-unpublished
```

## TikTok upload

Rendered MP4 files can also be uploaded to TikTok through the official Content
Posting API. The default mode is inbox upload, which sends the video to the
user's TikTok inbox/editing flow and requires a user token with `video.upload`.

```bash
TIKTOK_ACCESS_TOKEN="act..." \
  bin/ffmpeg_video_builder --tiktok-upload outputs/02062026_MyVideoTitle.mp4
```

Upload every output listed in a workspace manifest:

```bash
bin/ffmpeg_video_builder \
  --tiktok-access-token "act..." \
  --tiktok-upload-workspace workspace
```

Direct post is available when your TikTok app and user token support
`video.publish`:

```bash
bin/ffmpeg_video_builder \
  --tiktok-access-token "act..." \
  --tiktok-upload outputs/02062026_MyVideoTitle.mp4 \
  --tiktok-direct-post \
  --tiktok-title "Caption #fyp" \
  --tiktok-privacy-level SELF_ONLY \
  --tiktok-aigc
```

TikTok may restrict unaudited API clients to private visibility.

## Google AI Studio speech generation

The Google AI Studio speech UI is backed by Gemini API text-to-speech models.
Use an API key from AI Studio through `GOOGLE_AI_API_KEY` or `GEMINI_API_KEY`:

```bash
GOOGLE_AI_API_KEY="AIza..." \
  bin/ffmpeg_video_builder \
  --google-ai-tts-file workspace/script.txt \
  --google-ai-tts-output outputs/google_ai_speech.wav \
  --google-ai-tts-voice Kore \
  --google-ai-tts-style "Say calmly in a warm Indonesian narration style"
```

Inline text also works:

```bash
bin/ffmpeg_video_builder \
  --google-ai-api-key "AIza..." \
  --google-ai-tts "Halo dunia." \
  --google-ai-tts-output outputs/halo.wav
```

Manual JSON project configs are still supported:

```bash
bin/ffmpeg_video_builder examples/project.json
```

Search icons:

```bash
bin/ffmpeg_video_builder --icon-search "light bulb"
```

Icon searches download SVG assets into a new directory:

```text
projects/Project_INTEGER_SEQUENCE_DDMMYYYY/
```

The command also writes `icon_metadata.json` in that directory with the selected icon
IDs, licenses, source URLs, and local file paths.

Rebuild a generated project after editing `icon_plan.json`:

```bash
bin/ffmpeg_video_builder --rebuild-project projects/Project_1_02062026
```

The value is the generated project directory path, using the
`Project_SEQUENCE_DDMMYYYY` folder name:

```bash
bin/ffmpeg_video_builder --rebuild-project projects/Project_1_03062026
bin/ffmpeg_video_builder --rebuild-project projects/Project_42_03062026
```

For a bulk workspace, rebuild every project listed in the workspace manifest:

```bash
bin/ffmpeg_video_builder --rebuild-workspace workspace
```

This skips keyword icon search. Edit each entry's `icon_id` in `icon_plan.json`
to the exact Iconify ID you want, such as `fluent:money-24-regular`; the rebuild
downloads those exact icons, updates `icon_file`, regenerates `config_project.json`,
and renders the video again. Duplicate `icon_id` values are rejected so each icon
stays different within the project.

Generate narration audio with local Kokoro:

```bash
bin/ffmpeg_video_builder --kokoro-script script.txt
```

Kokoro audio is written into a new `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/` directory as
`audio_voiceover.wav`.

Create sentence timings and subtitles from audio with local Whisper:

```bash
bin/ffmpeg_video_builder --whisper-transcribe voiceover.mp3
```

Whisper analyzes an existing audio file. It does not create audio from a text
script; use a TTS tool or recorded voice first, then run Whisper to produce
sentence timestamps and subtitles.

Outputs are written into a new `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/` directory. The
default local Whisper model is `turbo`, the default output format is `json`, and
word timestamps are enabled so the script can derive sentence-level timing.

The JSON example will generate:

```bash
examples/output.mp4
```

## Project config

A minimal config:

```json
{
  "output": "output.mp4",
  "width": 1080,
  "height": 1920,
  "fps": 30,
  "duration": 8,
  "background": {
    "type": "color",
    "color": "#111827"
  },
  "elements": [
    {
      "type": "text",
      "text": "Simple idea. Strong visual.",
      "start": 0,
      "end": 4,
      "font_size": 60,
      "color": "white",
      "x": "center",
      "y": 500
    },
    {
      "type": "image",
      "file": "assets/idea.png",
      "start": 1,
      "end": 5,
      "width": 300,
      "x": "center",
      "y": 750,
      "animation": "pop"
    }
  ]
}
```

Relative file paths are resolved from the JSON file location.

## Audio

Add an audio file:

```json
{
  "audio": "voiceover.mp3"
}
```

The final output will end at the configured duration or audio/video duration, whichever is shorter.

### Kokoro narration

The script can call the local Kokoro helper at `bin/kokoro-tts`:

```bash
bin/ffmpeg_video_builder --kokoro-script script.txt
```

You can also pass short text directly:

```bash
bin/ffmpeg_video_builder --kokoro-speak "A short narration line."
```

Optional flags:

- `--kokoro-voice` - Kokoro voice, default `af_heart`
- `--kokoro-speed` - speech speed, default `1.0`
- `--kokoro-lang-code` - Kokoro language code, default `a`

If Kokoro is installed in a virtualenv, set:

```bash
KOKORO_PYTHON=/full/path/to/python bin/ffmpeg_video_builder --kokoro-script script.txt
```

### Whisper sentence timing

The script can call the local `openai/whisper` CLI to derive sentence start/end
times from an audio file:

```bash
bin/ffmpeg_video_builder --whisper-transcribe voiceover.mp3
```

This creates Whisper's JSON output plus:

- `subtitle_sentences.json` - sentence text with `start` and `end` seconds
- `subtitle_sentences.srt` - subtitle file using the same sentence timings

Optional flags:

- `--whisper-model` - local Whisper model, default `turbo`
- `--whisper-output-format` - `txt`, `vtt`, `srt`, `tsv`, `json`, or `all`; default `json`
- `--whisper-task` - `transcribe` or `translate`; default `transcribe`
- `--no-whisper-word-timestamps` - disable word timestamps and use segment timing fallback
- `--whisper-language` - optional language hint
- `--whisper-prompt` - optional initial prompt

If the `whisper` executable is not on `PATH`, set:

```bash
WHISPER_COMMAND=/full/path/to/whisper bin/ffmpeg_video_builder --whisper-transcribe voiceover.mp3
```

## Background options

### Solid color

```json
{
  "background": {
    "type": "color",
    "color": "#FFC067"
  }
}
```

If `background` is omitted, the default is a solid `#FFC067` color.

### Image background

```json
{
  "background": {
    "type": "image",
    "path": "background.jpg"
  }
}
```

You can also use `file` for local paths, or `url` for remote media:

```json
{
  "background": {
    "type": "image",
    "url": "https://example.com/background.jpg"
  }
}
```

### Video background

```json
{
  "background": {
    "type": "video",
    "path": "background.mp4"
  }
}
```

Video backgrounds also support `file`, `path`, or `url`.

## Element types

### Text

```json
{
  "type": "text",
  "text": "Your caption here",
  "start": 0,
  "end": 3,
  "font_size": 56,
  "color": "white",
  "x": "center",
  "y": 900,
  "box": true,
  "box_color": "black@0.4"
}
```

### Image/icon

```json
{
  "type": "image",
  "file": "assets/brain.png",
  "start": 0.5,
  "end": 3.5,
  "width": 320,
  "x": "center",
  "y": 600,
  "animation": "slide_left"
}
```

For automated icon search and download, use Iconify icon sets. Store the
selected icon ID, source URL, and icon set license with cached assets because
Iconify licenses are defined per icon set.

Default icon search source:

- `fluent` - Fluent UI System Icons, MIT

Supported icon search source options:

- `fluent` - Fluent UI System Icons, MIT
- `material-symbols-light` - Material Symbols Light, Apache 2.0
- `material-symbols` - Material Symbols, Apache 2.0
- `arcticons` - Arcticons, CC BY-SA 4.0
- `noto-v1` - Noto Emoji (v1), Apache 2.0

Icon source can be configured with either the Iconify prefix or a full Iconify
icon-set URL:

```json
{
  "icon": {
    "source": "noto-v1",
    "source_url": "https://icon-sets.iconify.design/noto-v1"
  }
}
```

The CLI also accepts either form:

```bash
bin/ffmpeg_video_builder --icon-source noto-v1 --icon-search "money"
bin/ffmpeg_video_builder --icon-source https://icon-sets.iconify.design/noto-v1 --icon-search "money"
```

Required icon search parameter:

- `keyword` - keyword to search

Default icon search parameters:

- `style` - `regular`
- `source` - `fluent`
- `license_type` - `permissive`
- `size` - `512`

The search command downloads the returned results as SVG files. Use
`--icon-limit 1` to download only the top match.

Supported `style` preferences include `bold`, `filled`, `regular`, `light`,
`outline`, `rounded`, and `sharp`.

Supported `license_type` values:

- `permissive` - no-attribution commercial-friendly sources, such as MIT and Apache 2.0
- `attribution` - attribution/share-alike sources, such as CC BY-SA 4.0
- `any` - allow any supported source license type

The `bold` style preference also matches `filled` icons because Fluent UI System
Icons uses filled variants instead of a bold variant.

### Audio waveform

```json
{
  "type": "waveform",
  "audio": "voiceover.mp3",
  "start": 0,
  "end": 8,
  "width": 320,
  "height": 64,
  "x": "center",
  "position": "bottom",
  "color": "0x111111",
  "opacity": 0.72
}
```

Script-generated videos include a small waveform below the icon by default. Set
`position` to `bottom` to place it below the icon, or `above` to place it above
the icon. In manual JSON configs, omit `audio` to reuse the root `audio` file.
You can still set `y` directly when you need an exact vertical position.

### Rectangle

```json
{
  "type": "rectangle",
  "start": 0,
  "end": 8,
  "x": 70,
  "y": 250,
  "width": 940,
  "height": 1180,
  "color": "white@0.08"
}
```

## Position values

For image/icon `x`:

- `left`
- `center`
- `right`
- any FFmpeg expression or pixel value

For image/icon `y`:

- `top`
- `center`
- `bottom`
- any FFmpeg expression or pixel value

For text `x`:

- `left`
- `center`
- `right`
- any FFmpeg expression or pixel value

For text `y`:

- `top`
- `center`
- `bottom`
- any FFmpeg expression or pixel value

## Create GitHub repo and push

Using GitHub CLI:

```bash
gh auth login
gh repo create ffmpeg-ruby-video-builder --public --source=. --remote=origin --push
```

Or manually:

```bash
git init
git add .
git commit -m "Initial FFmpeg Ruby video builder"
git branch -M main
git remote add origin git@github.com:YOUR_USERNAME/ffmpeg-ruby-video-builder.git
git push -u origin main
```

## Suggested next additions

- Subtitle file support
- Scene templates
- Ken Burns background animation
- Per-word caption highlighting
- Auto-generated project JSON from a script outline
