# Provider asset sources

## Ollama

`Sources/Assets.xcassets/glyph-ollama.imageset/ollama.svg` is the unchanged
[Ollama documentation mark](https://github.com/ollama/ollama/blob/83ed7d9965b1ee07e0f0b29fd46e47c31f0fcab8/docs/ollama-logo.svg),
retrieved on 2026-09-07. Its original 17:25 aspect ratio is preserved.

The asset catalog preserves its vector representation and marks it as a
template. `ProviderGlyphView` applies the same foreground color, fixed frame
and asset lookup used by the other providers, so the mark works on both the
dark notch and the Settings background.

## Devin

`glyph-devin` uses the current Devin Desktop mark — the three connected
hexagons — extracted from the installed app icon
(`/Applications/Devin.app/Contents/Resources/Devin.default.png`) on
2026-09-10. The white rounded-square plate was removed; the remaining black
mark was isolated on a transparent background and stored as
`devin.png`. The image set is marked as a template so
`ProviderGlyphView` tints it like the other provider glyphs.

## LM Studio

`Sources/Assets.xcassets/glyph-lmstudio.imageset/lmstudio.svg` is Lobe Icons'
monochrome LM Studio mark (`packages/static-svg/icons/lmstudio.svg`) from the
same pinned commit `a94750e3f5f8fc33757b839d85030e742284e43a`, retrieved
2026-09-10, adapted the same way as the brand marks below: `fill="#000"`,
numeric `width="24"` / `height="24"`, web-only style removed. The mark's
lighter second layer is a `fill-opacity` on the path and survives template
rendering as partial alpha, which is how the original reads too.
`LMStudioProviderTests.testTheGlyphAssetRendersAsAMarkNotASquare` checks the
native render.

## Local model brands

Qwen, Gemma, Meta (for Llama), DeepSeek and Mistral use monochrome vectors from
[Lobe Icons](https://github.com/lobehub/lobe-icons/tree/a94750e3f5f8fc33757b839d85030e742284e43a/packages/static-svg/icons),
pinned to commit `a94750e3f5f8fc33757b839d85030e742284e43a` and retrieved
2026-09-07. These are Lobe Icons' brand representations, not files claimed to
have been published directly by each model vendor.

| Local image set | Upstream file |
| --- | --- |
| `glyph-qwen` | `packages/static-svg/icons/qwen.svg` |
| `glyph-gemma` | `packages/static-svg/icons/gemma.svg` |
| `glyph-meta` | `packages/static-svg/icons/meta.svg` |
| `glyph-deepseek` | `packages/static-svg/icons/deepseek.svg` |
| `glyph-mistral` | `packages/static-svg/icons/mistral.svg` |

Path geometry and the 24 × 24 view box are preserved. For native asset-catalog
compatibility, the root uses `fill="#000"` and numeric `width="24"` /
`height="24"`; the web-only `flex`/`line-height` style is removed. Keeping
`currentColor` and `1em` produced solid placeholder squares in the native view.
All five image sets preserve vector data and use template rendering.

The upstream MIT copyright and license are included in
`Sources/Resources/LobeIcons-LICENSE.txt` and copied into the app bundle.
`LocalModelBrandTests` verifies asset lookup, nonempty nonrectangular native
rendering and the bundled license; notch and tooltip fixtures cover all marks.
