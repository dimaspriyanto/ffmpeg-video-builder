# Config Reference

## Script pipeline

The primary bundle input is a text script:

```bash
bin/ffmpeg_video_builder script.txt
```

The pipeline generates narration with local Kokoro, derives sentence subtitles
with local Whisper, chooses icon keywords from the subtitle sentences, downloads
matching Iconify icons, writes a generated `config_project.json`, and renders the final
video with FFmpeg.

## Workflow Modes

| Mode | Single script | Workspace bulk |
|---|---|---|
| Prepare project assets only | `bin/ffmpeg_video_builder --until-icons script.txt` | `bin/ffmpeg_video_builder --bulk-workspace workspace --until-icons` |
| Prepare assets and render video | `bin/ffmpeg_video_builder script.txt` | `bin/ffmpeg_video_builder --bulk-workspace workspace` |
| Regenerate after editing icons | `bin/ffmpeg_video_builder --rebuild-project projects/Project_1_02062026` | `bin/ffmpeg_video_builder --rebuild-workspace workspace` |

To stop after project structure, narration, subtitles, icon search/download,
`icon_plan.json`, and `config_project.json` are created, use:

```bash
bin/ffmpeg_video_builder --prepare-only script.txt
bin/ffmpeg_video_builder --until-icons script.txt
```

Bulk generation uses one workspace directory and one text file containing
multiple script blocks:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace
```

The default script file is `workspace/scripts.txt`. You can pass another file:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace --bulk-scripts workspace/my-scripts.txt
```

Each block uses the same `Title`, `Category`, and `Content` format:

```text
Title: First Video
Category: Financial Advice

Content:
First script content.

Title: Second Video
Category: Financial Advice

Content:
Second script content.
```

Bulk generation writes one normal project directory per script. It also writes
`bulk_manifest.json` into the workspace with the generated project paths.

Bulk prepare-only mode creates every project structure and downloads icons
without rendering MP4 files:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace --prepare-only
bin/ffmpeg_video_builder --bulk-workspace workspace --until-icons
```

After editing `icon_plan.json` in projects created from a bulk workspace,
regenerate every project listed in `workspace/bulk_manifest.json`:

```bash
bin/ffmpeg_video_builder --rebuild-workspace workspace
```

To refresh the exact icon downloads and configs without rendering MP4 files:

```bash
bin/ffmpeg_video_builder --rebuild-workspace workspace --until-icons
```

## Workspace Config

Workspace generation reads `workspace/config.json` when it exists. Values in
that file override built-in defaults. Command-line flags override `config.json`.

The same config is used when running a single script from that directory, such
as `bin/ffmpeg_video_builder workspace/script.txt`.

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

Workspace background behavior:

- If the workspace contains `background.png`, `background.jpg`,
  `background.mp4`, or another supported `background.*` media file, it is used
  for every generated video.
- If the workspace contains exactly one supported image/video media file, it is
  used as the background.
- If no media file exists, the solid `#FFC067` background is used.
- If multiple media files exist and none is named `background.*`, pass
  `--background-image` or `--background-video`.

Explicit background overrides:

```bash
bin/ffmpeg_video_builder --bulk-workspace workspace --background-color "#FFC067"
bin/ffmpeg_video_builder --bulk-workspace workspace --background-image workspace/background.png
bin/ffmpeg_video_builder --bulk-workspace workspace --background-video workspace/background.mp4
```

Generated project files are written into `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/`:

For example, the first project created on June 2, 2026 is written to
`projects/Project_1_02062026/`.

- `script_input.txt`
- `audio_voiceover.wav`
- `subtitle_sentences.json`
- `subtitle_sentences.srt`
- `icon_plan.json`
- `config_project.json`
- `DDMMYYYY_TitleOfTheVideo.mp4`

After a successful render, the final MP4 is moved into `outputs/`. The project
metadata file is updated with the moved `output_file` path. Bulk workspace
manifests are also updated with the moved output paths.

For script-driven projects, the rendered video filename is built from the
project date and script title. For example, a script titled `My Video Title`
created on June 2, 2026 renders to `outputs/02062026_MyVideoTitle.mp4`.

To regenerate a completed project after manually correcting icons, edit
`icon_plan.json` and set each entry's `icon_id` to the exact Iconify ID you want,
then run:

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

This skips keyword icon search, downloads the exact `icon_id` values into the
project's `icons/` folders, rewrites `icon_plan.json` with updated `icon_file`
paths, regenerates `config_project.json`, and renders the video again.

Manual JSON project configs are still supported:

```bash
bin/ffmpeg_video_builder examples/project.json
```

## Root fields

| Field | Type | Default | Description |
|---|---:|---:|---|
| `output` | string | `video_output.mp4` | Output video file path. |
| `width` | integer | `1080` | Video width. |
| `height` | integer | `1920` | Video height. |
| `fps` | integer | `30` | Frames per second. |
| `duration` | number | `10` | Video duration in seconds. |
| `background` | object | solid `#FFC067` color | Background config. |
| `audio` | string | none | Optional audio file. |
| `font_file` | string | none | Optional default font file for text. |
| `elements` | array | `[]` | Ordered visual elements. |

## Background

```json
{ "type": "color", "color": "#FFC067" }
```

```json
{ "type": "image", "path": "background.jpg" }
```

```json
{ "type": "video", "path": "background.mp4" }
```

Image and video backgrounds accept `file` or `path` for local media, and `url`
for remote HTTP(S) media:

```json
{ "type": "image", "url": "https://example.com/background.jpg" }
```

## Text element

| Field | Type | Default |
|---|---:|---:|
| `type` | string | required, must be `text` |
| `text` | string | required |
| `start` | number | `0` |
| `end` | number | video duration |
| `font_size` | integer | `54` |
| `color` | string | `white` |
| `x` | string/number | `center` |
| `y` | string/number | video height - 260 |
| `box` | boolean | `false` |
| `box_color` | string | `black@0.45` |
| `box_border` | integer | `28` |
| `font_file` | string | root `font_file` |

## Image/icon element

| Field | Type | Default |
|---|---:|---:|
| `type` | string | required, `image` or `icon` |
| `file` | string | required |
| `start` | number | `0` |
| `end` | number | video duration |
| `width` | integer | `300` |
| `opacity` | number | `1.0` |
| `x` | string/number | `center` |
| `y` | string/number | `center` |
| `animation` | string | `fade` |

Automated icon search/download should use Iconify icon sets. Cache downloaded
assets together with the selected icon ID, source URL, and icon set license.

Default Iconify search source:

- `fluent` - Fluent UI System Icons, MIT

Supported Iconify search source options:

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

Icon search parameters:

| Field | Type | Default |
|---|---:|---:|
| `keyword` | string | required |
| `style` | string | `regular` |
| `source` | string | `fluent` |
| `license_type` | string | `permissive` |
| `size` | integer | `512` |

Icon searches download SVG assets into `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/` and write
`icon_metadata.json` in the same directory with selected icon IDs, licenses, source
URLs, and local file paths.

Supported `style` preferences include `bold`, `filled`, `regular`, `light`,
`outline`, `rounded`, and `sharp`. The `bold` preference also matches `filled`
icons because Fluent UI System Icons uses filled variants instead of a bold
variant.

Supported `license_type` values:

- `permissive` - no-attribution commercial-friendly sources, such as MIT and Apache 2.0
- `attribution` - attribution/share-alike sources, such as CC BY-SA 4.0
- `any` - allow any supported source license type

## Local Kokoro narration

The script can call the local Kokoro helper at `bin/kokoro-tts` to generate
narration audio. Kokoro installation is intentionally not handled by this
bundle.

Outputs are written into `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/`, including
`audio_voiceover.wav` and `audio_kokoro.json`.

| CLI option | Type | Default |
|---|---:|---:|
| `--kokoro-speak` | string | direct text input |
| `--kokoro-script` | string | text file input |
| `--kokoro-voice` | string | `af_heart` |
| `--kokoro-speed` | number | `1.0` |
| `--kokoro-lang-code` | string | `a` |

If Kokoro is installed in a virtualenv, set `KOKORO_PYTHON` to the full path of
that Python executable. Set `KOKORO_SCRIPT` only if you move the helper script
away from `bin/kokoro-tts`.

## Local Whisper sentence timing

The script can call the local `openai/whisper` CLI to derive sentence start/end
times from an existing audio file. Whisper does not create audio from a text
script; create or record audio first, then run Whisper to produce subtitle
timings.

Outputs are written into `projects/Project_INTEGER_SEQUENCE_DDMMYYYY/`, including
`subtitle_sentences.json` and `subtitle_sentences.srt`.

| CLI option | Type | Default |
|---|---:|---:|
| `--whisper-transcribe` | string | required audio file |
| `--whisper-model` | string | `turbo` |
| `--whisper-output-format` | string | `json` |
| `--whisper-task` | string | `transcribe` |
| `--whisper-word-timestamps` | boolean | enabled |
| `--whisper-language` | string | none |
| `--whisper-prompt` | string | none |

If `whisper` is not on `PATH`, set `WHISPER_COMMAND` to the full path of the
local executable.

Animations:

- `none`
- `fade`
- `pop`
- `slide_left`
- `slide_right`
- `slide_up`
- `slide_down`

## Audio waveform element

| Field | Type | Default |
|---|---:|---:|
| `type` | string | required, must be `waveform` |
| `audio` | string | root `audio` |
| `start` | number | `0` |
| `end` | number | video duration |
| `width` | integer | `320` |
| `height` | integer | `64` |
| `x` | string/number | `center` |
| `position` | string | `bottom` |
| `y` | string/number | none |
| `color` | string | `0x111111` |
| `opacity` | number | `0.72` |
| `mode` | string | `cline` |
| `scale` | string | `sqrt` |
| `remove_background` | boolean | `true` |

Script-generated videos include a compact waveform below the icon by default.
Set `position` to `bottom` for below-icon placement or `above` for above-icon
placement. Set `y` directly to override relative placement.

## Rectangle element

| Field | Type | Default |
|---|---:|---:|
| `type` | string | required, must be `rectangle` |
| `start` | number | `0` |
| `end` | number | video duration |
| `x` | string/number | `0` |
| `y` | string/number | `0` |
| `width` | string/number | video width |
| `height` | string/number | `200` |
| `color` | string | `black@0.35` |
