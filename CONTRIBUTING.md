# Contributing

Thanks for considering it! AstroSharper is a single-maintainer project and the bar for new code is "would I want to keep maintaining this in five years". That said, focused PRs are very welcome.

## Quick start

```bash
git clone https://github.com/joergsflow/astrosharper.git
cd astrosharper
xcodegen generate
open AstroSharper.xcodeproj
```

Build & run from Xcode. Tests live in `Tests/EngineTests/` (run with `⌘U`).

## Before opening a PR

1. **Read the lessons file** — `tasks/lessons.md` lists patterns that have already been corrected. Don't re-introduce them.
2. **Read the architecture** — `docs/ARCHITECTURE.md` is the map of the codebase.
3. **Match the style** — no emojis in code, English comments, indentation matches the surrounding file.
4. **Pixel-test what you change** — if you touch a Metal kernel, add a test in `Tests/EngineTests/` with a known input/output. CPU reference is fine.
5. **Don't add backwards-compatibility shims** — this is a 0.x project. Breaking changes are OK.

## What's likely to be merged

- Bug fixes with reproducible test cases
- Performance improvements with benchmark numbers
- New file-format readers (FITS, RAW, DNG)
- New alignment / sharpening modes with a clear use case
- Documentation improvements

## What's likely to be rejected

- Lua scripting / batch CLI (explicit non-goal)
- Windows / Linux ports (explicit non-goal)
- Heavy refactors without a concrete payoff
- Adding dependencies just to use them
- Style-only churn

## Issues

When filing a bug:

- macOS version + Mac model (Apple Silicon / Intel)
- AstroSharper version (Help → About → version line)
- Reproducible steps
- A small sample file that triggers it (under 100 MB please)
- Console log if it crashed

## Testing on your end

Keep at least one full SER capture per supported target (Sun white-light, Sun Hα, Moon, Jupiter, Saturn, Mars) so you can verify changes don't regress those scenarios. The `TESTIMAGES/` folder is gitignored — bring your own.

## Code of conduct

Be kind. Astrophotography is a hobby; this app is a love letter to it.
