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

Automated icon search/download should use Iconify icon sets. Cache downloaded
assets together with the selected icon ID, source URL, and icon set license.

Default Iconify search source:

- `fluent` - Fluent UI System Icons, MIT

Supported Iconify search source options:

- `fluent` - Fluent UI System Icons, MIT
- `material-symbols-light` - Material Symbols Light, Apache 2.0
- `material-symbols` - Material Symbols, Apache 2.0
- `arcticons` - Arcticons, CC BY-SA 4.0

Icon search parameters:

| Field | Type | Default |
|---|---:|---:|
| `keyword` | string | required |
| `style` | string | `regular` |
| `source` | string | `fluent` |
| `license_type` | string | `permissive` |
| `size` | integer | `512` |

Icon searches download SVG assets into `downloads/projects_RANDOM_ID/` and write
`icons.json` in the same directory with selected icon IDs, licenses, source
URLs, and local file paths.

Supported `style` preferences include `bold`, `filled`, `regular`, `light`,
`outline`, `rounded`, and `sharp`. The `bold` preference also matches `filled`
icons because Fluent UI System Icons uses filled variants instead of a bold
variant.

Supported `license_type` values:

- `permissive` - no-attribution commercial-friendly sources, such as MIT and Apache 2.0
- `attribution` - attribution/share-alike sources, such as CC BY-SA 4.0
- `any` - allow any supported source license type

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
