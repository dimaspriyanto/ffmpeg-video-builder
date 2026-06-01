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

Check FFmpeg:

```bash
ffmpeg -version
```

## Usage

From the repository root:

```bash
chmod +x bin/ffmpeg_video_builder
bin/ffmpeg_video_builder examples/project.json
```

Dry-run only:

```bash
bin/ffmpeg_video_builder --dry-run examples/project.json
```

The example will generate:

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

## Background options

### Solid color

```json
{
  "background": {
    "type": "color",
    "color": "#111827"
  }
}
```

### Image background

```json
{
  "background": {
    "type": "image",
    "file": "background.jpg"
  }
}
```

### Video background

```json
{
  "background": {
    "type": "video",
    "file": "background.mp4"
  }
}
```

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
- Audio waveform visualization
- Auto-generated project JSON from a script outline
