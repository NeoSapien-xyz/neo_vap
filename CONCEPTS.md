# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## VAP assets

### VAP
A transparent (alpha) animation delivered as an ordinary opaque video: each frame packs the subject's colour and its alpha matte into separate regions of one video frame, which the plugin recomposites into premultiplied RGBA at playback. Chosen over a per-frame image sequence or alpha-capable codecs because it decodes on stock hardware video decoders.

### vapc
The metadata descriptor embedded in a VAP file that tells the player how to recomposite it — the content size plus the rectangles locating the colour and alpha regions within the encoded frame. Without it a VAP is just an opaque stacked video.

### Content size
The size of the recomposited output the player hands the app — the subject as it appears on screen. Distinct from the **video size**, the whole encoded frame that also carries the separately-stored alpha region and any padding; the video frame is always larger than the content.

Its ratio, the **content aspect**, is reported to the app once the clip is opened, so a view can size itself against the clip's real proportions instead of a hardcoded value. The ratio alone determines layout, but a box carrying it still has an absolute size, and that size is what reaches the renderer — so it is expressed in real pixels, never as a bare ratio.

### Design box
The fixed rectangle a clip is composed to occupy on screen, taken from the design comp. An asset is cut at the design box's aspect so the composited content fills it without letterboxing, and the subject is framed *within* it with **motion headroom** rather than filling it edge to edge. Distinct from **content size**, which is the asset's own output resolution — the design box is where that output lands.

### RGB region / Alpha region
The two rectangles a VAP frame is split into: the RGB region holds straight (non-premultiplied) subject colour, the alpha region holds the matte as luminance. The alpha region is commonly stored at reduced resolution since a matte is low-frequency, and the player scales it back up when compositing.

### Motion headroom
The transparent margin an animated subject is deliberately composed within, giving it room to rotate, scale, or drift across frames without touching the frame edge. It is composition, not wasted space — cropping it away makes the subject collide with a fixed display box and clip as it animates.
