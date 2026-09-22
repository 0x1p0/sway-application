# Sway app icon

A silver-white, flowing swipe mark on a charcoal rounded tile. The mark suggests
both an S and a continuous trackpad gesture, without tiny controls or lettering.

Created with the built-in image-generation tool. The final generated artwork
was normalized to the 1024-pixel master and downsampled for the existing macOS
asset catalog, preserving transparency. No generation service runs in the app.

Master: `Sway/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png`.
Regenerate the smaller sizes with `bash scripts/update-app-icon.sh`, or pass a
new square PNG as the first argument to replace the master and every size.
Both the Xcode build and the direct-build fallback consume this asset set.

## Generation prompt

```text
Use case: logo-brand
Asset type: production macOS app icon, a single square 1024 x 1024 PNG.
Primary request: Create an original, beautifully restrained icon for Sway, a minimal Mac utility that adjusts volume and brightness with fluid trackpad-edge swipes. Replace its clumsy old literal trackpad illustration with a distinctive fluid S-shaped gesture mark.
Composition: perfectly front-facing, centered, no perspective. One charcoal-black rounded-square macOS-style tile, occupying about 88% of the canvas, with equal transparent margins. A bold silver-white flowing S-shaped ribbon mark centered in the tile, occupying about 55% of canvas height. The S has beautifully balanced curves, soft rounded terminals, a strong uninterrupted silhouette and generous negative space, recognizable at 16 pixels. It suggests a smooth finger swipe and gentle motion, not a typed letter. It must read as a single confident symbol, not tangled loops.
Style: refined monochrome native-desktop icon craft, subtle luminous glass/porcelain relief on the mark, a very restrained soft highlight on the dark tile's upper rim, smooth charcoal surface, quiet shallow depth, not a glossy toy. The graphic silhouette is far more important than tiny material detail.
Palette: strictly neutral black, graphite, silver, white; no colored tint.
Background: actual transparent alpha outside the rounded tile, not a baked checkerboard or white background. Keep all geometry within the square canvas with safe margins. Small soft shadow is fine.
Constraints: one final icon only; no presentation board, no text or wordmark, no numbers, no tiny control glyphs, no speaker/sun illustration, no border frame around the canvas, no Apple logo, no watermark, no dramatic chrome reflections. Deliver ready-to-use icon artwork, not an icon shown in a mockup.
```
