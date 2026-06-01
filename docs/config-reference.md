# Config Reference

## Root fields

| Field | Type | Default | Description |
|---|---:|---:|---|
| `output` | string | `output.mp4` | Output video file path. |
| `width` | integer | `1080` | Video width. |
| `height` | integer | `1920` | Video height. |
| `fps` | integer | `30` | Frames per second. |
| `duration` | number | `10` | Video duration in seconds. |
| `background` | object | color black | Background config. |
| `audio` | string | none | Optional audio file. |
| `font_file` | string | none | Optional default font file for text. |
| `elements` | array | `[]` | Ordered visual elements. |

## Background

```json
{ "type": "color", "color": "#111827" }
```

```json
{ "type": "image", "file": "background.jpg" }
```

```json
{ "type": "video", "file": "background.mp4" }
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

Animations:

- `none`
- `fade`
- `pop`
- `slide_left`
- `slide_right`
- `slide_up`
- `slide_down`

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
