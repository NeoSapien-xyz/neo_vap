---
title: "Alpha-VAP asset cropping: keep the transparent margins — crop to the design box, not the opaque bbox"
date: 2026-07-16
last_refreshed: 2026-07-29
category: best-practices
module: neo_vap
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - "Preparing or re-cropping an alpha (transparent) VAP video asset from source frames"
  - "The source render carries intentional transparent margins / motion headroom around the subject"
  - "Sizing a NeoVapView (external Texture) that has no intrinsic size and fills its parent"
  - "Choosing a BoxFit for an alpha video meant to match a Figma / design-box composition"
symptoms:
  - "A tightly cropped VAP looks like it crops from all over as it animates (subject shoved against fixed box edges)"
  - "Faint glow / highlight is hard-clipped when cropping to the opaque bbox with a threshold"
root_cause: logic_error
resolution_type: code_fix
tags: [vap, alpha-video, ffmpeg, flutter, texture, cropping, aspect-ratio, compositing]
related_components: [vapc_parser, neo_vap_example]
---

# Alpha-VAP asset cropping: keep the transparent margins — crop to the design box, not the opaque bbox

## Context

`neo_vap` plays transparent-alpha VAP videos into a Flutter texture. An alpha VAP is a normal `.mp4` carrying an RGB (color) region and a **half-resolution alpha region** in one frame. A top-level mp4 box named `vapc` carries a JSON descriptor — this is the shipped pendant's, read back from the file:

```json
{"info":{"v":2,"f":218,"w":710,"h":1134,"fps":25,"videoW":710,"videoH":1712,
         "rgbFrame":[0,0,710,1134],"aFrame":[0,1142,355,567],"isVapx":0,"orien":0}}
```

- `w`/`h` = **content** size — the composited output the compositor produces.
- `videoW`/`videoH` = the full encoded mp4 frame.
- `rgbFrame`/`aFrame` = `[x,y,w,h]` rects that crop the color and alpha planes out of the mp4.

**The rects decide the layout — there is no fixed one.** The pendant above is top-bottom (alpha below RGB). The `active_mode` clips in the same example app are **side-by-side**: `rgbFrame [0,0,1000,1000]`, `aFrame [1004,0,500,500]` — alpha to the *right*. Nothing in the player assumes stacking; it reads the rects. Do not write code, or a doc, that assumes top-bottom.

The task that produced this learning: an animated pendant asset needed re-cutting. The intuition was "the pendant floats tiny in a huge transparent frame — crop the waste." That intuition was wrong, and cropping tight to the subject produced an asset that "crops from all over the place" and looked broken. This documents why, and the correct re-cut recipe.

## Guidance

**Transparent margins around an animated subject are the artist's composition and motion headroom, not waste. Do not crop to the subject's bounding box.**

An animated VAP subject rotates, scales, and bobs *within* its frame every frame. The `vapc` content box (`w`/`h`) is a **fixed** display rectangle. Crop tight to the subject's bounding box and the subject fills that fixed box edge-to-edge at rest — so the moment any per-frame rotation/scale/bob kicks in, the subject is shoved against the box edges and its soft glow is hard-clipped. Because the subject rotates, the clipped edge *moves*, so the clip jitters frame to frame. That is the "crops from all over the place" failure.

The correct re-cut keeps the margins: crop the **full render height** at the **design box aspect**, centered on the subject, **including the full glow**, then downscale to retina content size. Let native report the content aspect via the `vapc` `w`/`h` (an `info` event), and render with `BoxFit.contain` inside a design-sized `SizedBox`. The subject lands at ~50% of the box with breathing room and stays stable across the whole animation.

### The mechanical recipe (reusable)

Re-encode a VAP asset from a PNG sequence (top-bottom layout, half-res alpha). `CW/CH/CX/CY` = crop rect out of the source PNG; `OW/OH` = output content size; `VIDEOH = OH + OH/2`; `AY = OH` (alpha starts right below the RGB region):

```bash
ffmpeg -y -framerate 25 -start_number 5 -i "frames/name.%04d.png" \
 -filter_complex "\
[0:v]crop=CW:CH:CX:CY,split=2[craw][araw];\
[craw]scale=OW:OH,setsar=1,format=rgb24[top];\
[araw]format=rgba,alphaextract,scale=OW/2:OH/2,format=rgb24[ah];\
color=c=black:s=OWxVIDEOH:r=25,format=rgb24[bg];\
[bg][top]overlay=0:0:shortest=1[t1];\
[t1][ah]overlay=0:AY[v]" \
 -map "[v]" -r 25 -c:v libx264 -pix_fmt yuv420p -crf 22 -preset slow -an out.mp4
```

Then append a `vapc` box (Python, post-mux):

```python
import struct, json
info={"info":{"v":2,"f":218,"w":OW,"h":OH,"fps":25,"videoW":OW,"videoH":VIDEOH,
      "aFrame":[0,AY,OW//2,OH//2],"rgbFrame":[0,0,OW,OH],"isVapx":0,"orien":0}}
js=json.dumps(info,separators=(',',':')).encode()
box=struct.pack('>I',8+len(js))+b'vapc'+js
open('out_vap.mp4','wb').write(open('out.mp4','rb').read()+box)
```

**Do not trust the arithmetic — read `VIDEOH` and `AY` back off the encoded file.** The formulas above are what you *intend*; the encoder pads to its own alignment, and none of the four shipped assets match the naive values:

| asset | content `h` | `OH+OH/2` | actual `videoH` | recipe `AY=OH` | actual `aFrame` y |
|---|---|---|---|---|---|
| gunmetal pendant | 1134 | 1701 | **1712** | 1134 | **1142** |
| gunmetal lowres | 846 | 1269 | **1272** | 846 | **847** |
| active_mode (side-by-side) | 1000 | 1500 | **1008** | 1000 | **0** (x=1004) |

Every one carries a **gutter** between the two regions (8px, 1px, 4px respectively) and an encoded height the formula does not predict. Append a `vapc` built from the arithmetic onto a frame the encoder padded and the rects point at the wrong rows — the alpha plane samples a few lines off, which reads as a soft edge fringe rather than an obvious break, so it survives a casual look. Probe the muxed file first and write those numbers:

```bash
ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 out.mp4
```

Measure the true subject extent (including faint glow) with a **low** cropdetect threshold before choosing the crop:

```bash
ffmpeg -i "frames/name.%04d.png" -vf alphaextract,cropdetect=1:2:1 -f null -   # true visible extent
# NOT cropdetect=16:2:1 — threshold 16 excludes faint glow/shadow
```

## Why This Matters

- **Stability.** With margins preserved and `BoxFit.contain`, the subject rotates *inside* its box and the box edge never touches it. No moving clip, no jitter. The tight crop failed on exactly this: the subject rotated into the fixed edges.
- **Glow fidelity.** Soft glow and shadow are the subject. Cropping them off (or clipping them at a high cropdetect threshold) removes the very pixels that read as "premium." In the concrete case the tight `cropdetect=16` crop clipped **~84px** of faint top-loop glow.
- **The margins are already efficient.** The old asset's margins were not bloat added by a lazy artist — they were the full render canvas. There was nothing to reclaim; cropping only did damage.
- **Composition intent.** The artist framed the subject small-and-centered on purpose. `BoxFit.contain` against a design-sized box reproduces that framing for free; a tight crop overrides it.

## When to Apply

**Apply** when re-cutting an **animated** VAP asset — anything with per-frame rotation, scale, bob, drift, or a soft glow/shadow. Preserve the margins; crop at the design-box aspect over the full render height; include the glow; let native report the aspect and use `BoxFit.contain`.

**Do NOT apply** (i.e. trimming *is* fine) when an asset has genuinely wasteful, **uniform, static** padding — e.g. a static logo exported onto a 4K canvas with 40% dead transparent border on every side and no animation. There the bounding box is stable frame to frame, nothing rotates into the edges, and trimming to a modest margin is legitimate. The test: **does the subject move relative to its bounding box across frames?** If yes, keep the headroom. If the bbox is rock-steady and the padding is uniform waste, trim it — but still leave a small margin and never clip the glow.

Rule of thumb: match the content aspect (`vapc` `w`/`h`) to the design-box aspect so `contain` fills the container cleanly; prefer that over hardcoding an aspect + `BoxFit.cover`.

## Examples

### The concrete case

Old gunmetal asset: content **1504×846** (16:9), pendant floating small and centered in large transparent margins. It was **not** cropped — it was the full **3840×2160** render canvas downscaled 2.55×. The margins were intended headroom.

### Wrong: tight crop to the bounding box

Source: 218 RGBA PNGs @ 3840×2160. Measured the union opaque bbox with the high threshold:

```bash
ffmpeg -i frames -vf alphaextract,cropdetect=16:2:1 -f null -   # → 626×1066
```

Cropped tight to **656×1096**, re-encoded. Looked horrendous. The adversarial per-frame data explains why:

- Per-frame center drift: only **7px** in x, **63px** in y → the subject is essentially stationary.
- Width **578→626** across frames, height ~constant → the subject **rotates in place**.
- True extent at the low threshold `cropdetect=1:2:1` = **666×1180**, so the tight `limit=16` crop clipped **~84px** of faint glow off the top loop.

Two failures compounded: (a) no breathing room, so rotation pushed the subject into the fixed box edges; (b) glow hard-clipped, and because the subject rotates, the clipped edge moved — the clip jittered every frame.

### Right: full-height crop at the design-box aspect

Crop the **full height (2160)** at the **design-box aspect** `0.626` (the Figma pendant box is 236.55×377.87 → 236.55/377.87 ≈ 0.626), centered on the subject, **including the full glow**. Downscale to retina content **710×1134**.

- Native reports aspect **0.626** via the `info` event.
- `BoxFit.contain` fills the design-sized `SizedBox` cleanly.
- Pendant sits at **~49% width / ~55% height** with margin, stable across the whole animation.
- File size **422 KB**.

## Gotchas

1. **Measure glow at a LOW threshold.** `cropdetect=16` excludes faint glow/shadow. Use `cropdetect=1:2:1` for the true visible extent, or the moving clipped edge will jitter as the subject animates.
2. **`alphaextract` needs raw RGBA.** Split **before** scale and scale **inside** each branch. Feeding a scaled output into `alphaextract` errors with `Failed to configure input pad on Parsed_alphaextract`.
3. **RGB region is straight (non-premultiplied) color.** These renders export transparent pixels as `(0,0,0,0)`, so `format=rgb24` yields straight color where opaque and black elsewhere. The compositor does `color*alpha`, so do **not** premultiply — premultiplying would double-darken the edges.
4. **Inject `vapc` by APPENDING a top-level box after `mdat`.** The `mdat` sample offsets stay valid and players skip unknown boxes; the parser scans all top-level boxes, so position doesn't matter. (The original authoring tool placed `vapc` *before* `mdat`, which requires correct offsets at mux time — appending is the safe post-mux way.)
5. **`NeoVapView` has no intrinsic size — it fills its parent.** "Zoomed to eternity" = an unbounded parent (a full-screen `Expanded`). Size it by wrapping in a `SizedBox`/`Center` at the design box; the container sets the on-screen size, not the asset.
6. **Prefer native-reported aspect + `BoxFit.contain`** over a hardcoded aspect + `BoxFit.cover`. Match the content aspect (`vapc` `w`/`h`) to the design-box aspect so `contain` fills the container without letterboxing.
7. **A box carrying an aspect ratio still needs real pixel dimensions.** Taking gotcha 6 means the view sizes itself from the reported aspect rather than an explicit one — a different code path, and the one where a portrait clip (aspect < 1) once rendered completely blank on Android. Expressing the ratio as a unit box (`SizedBox(width: ar, height: 1)`) inside a `FittedBox` is the trap: `FittedBox` scales painting, not layout, so that literal sub-pixel size reaches the external texture layer and Impeller's GLES backend truncates it to zero width. Scale the box. See [`ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md`](../ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md).

## Related

- [`ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md`](../ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md) — **closest neighbour.** Same pendant asset (710×1134, aspect 0.626) and the same sizing surface: this doc prescribes the strategy, that one documents the failure mode of implementing it with a sub-pixel aspect box. Read both before changing how `NeoVapView` sizes itself.
- [`architecture-patterns/texture-plugin-prewarm-hardening.md`](../architecture-patterns/texture-plugin-prewarm-hardening.md) — same plugin, native cold-start prewarm. Distinct area (runtime pipeline, not asset authoring); low overlap.
- [`architecture-patterns/flutter-plugin-shared-eventchannel.md`](../architecture-patterns/flutter-plugin-shared-eventchannel.md) — same plugin, shared EventChannel backend. Distinct area; low overlap.
