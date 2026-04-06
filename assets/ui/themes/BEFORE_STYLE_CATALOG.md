# BEFORE State — Hand-rolled StyleBox Catalog

Captured 2026-04-06 before Phase A theme extraction. This is the source of truth
for the visual regression test — `default_theme.tres` must reproduce these
values exactly (or within the documented tolerance) or the refactor failed.

Research doc `docs/DIALOGUE_RESEARCH.md` claimed border color `#402614`. **Wrong.**
Actual border is `#735940`. The `#402614` value is the title-text color, not the
border. Documented below from verified source.

---

## 1. Parchment panel (primary)

Used by: `book_viewer.gd:139`, `journal_panel.gd:156`, `test_dialogue.gd:335` (response panel).

| Prop | Value (RGB float) | Hex |
|------|-------------------|-----|
| bg_color | (0.91, 0.87, 0.78) | `#E8DEC7` |
| border_color | (0.45, 0.35, 0.25) | `#735940` |
| border_width (all) | 3 (book, journal) / 2 (test_dialogue response) | |
| corner_radius (all) | 4 | |
| content_margin (all) | 20 (book, journal) / 15 (test_dialogue response) | |

Variations needed in theme: `PanelContainer` default = 3/20, variation `ParchmentTight` = 2/15.

## 2. Toast dark

Used by: `toast.gd:50`. Only style on toasts. Distinct from parchment.

| Prop | Value | Hex |
|------|-------|-----|
| bg_color | (0.12, 0.10, 0.08, 0.9) | `#1F1914` @ 0.9 alpha |
| border_color | (0.60, 0.50, 0.35) | `#998059` |
| border_width (all) | 1 | |
| corner_radius (all) | 6 | |
| content_margin (all) | 12 | |

Theme variation: `Toast` (applied to the toast `PanelContainer`).

## 3. Topics dark (scratch list panel)

Used by: `test_dialogue.gd:359`. Will move into dialogue panel when extracted in Phase B.

| Prop | Value | Hex |
|------|-------|-----|
| bg_color | (0.12, 0.12, 0.15) | `#1F1F26` |
| border_color | (0.30, 0.30, 0.40) | `#4D4D66` |
| border_width (all) | 2 | |
| corner_radius (all) | 4 | |
| content_margin (all) | 10 | |

Theme variation: `TopicsList`.

## 4. Book separator

Used by: `book_viewer.gd:174`. Inline HSeparator style.

| Prop | Value | Hex |
|------|-------|-----|
| bg_color | (0.45, 0.35, 0.25, 0.5) | `#735940` @ 0.5 alpha |
| content_margin_top | 1 | |
| content_margin_bottom | 1 | |

Theme variation: `ParchmentSeparator` (applied via `HSeparator/separator` override).

---

## Text / font-size catalog

| Where | font_size | font_color | Hex |
|-------|-----------|------------|-----|
| Title labels (book, journal, dialogue) | 22 | (0.25, 0.15, 0.1) | `#40261A` |
| Close button | 18 | default | |
| Body text (RichTextLabel) | 16 | (0.15, 0.10, 0.05) | `#261A0D` |
| Disposition label | 16 | (0.6, 0.7, 0.6) | `#99B399` |
| Topics list | 16 | default | |
| Info label | default | default | |
| Toast label | 16 | (0.9, 0.85, 0.7) | `#E6D9B3` |

## Acceptance criteria for AFTER (Phase A-7)

- bg / border colors exact match (color picker on screenshot = same hex)
- font_size within ±1px (font change from default serif → Pelagiad acceptable)
- border widths + corner radii exact
- content margins exact
- no new padding/margin that isn't documented above
