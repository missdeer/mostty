# ghostty-sprite (vendored)

Vendored from [ghostty](https://github.com/ghostty-org/ghostty) at commit
`aac491657be1c17f214a32c6ee0b1a221bf99bd1` (1.3.2-dev).

These files implement Ghostty's procedural drawing of Block Elements, Box
Drawing, Braille, Powerline, Geometric Shapes, and Legacy Computing symbols.
Mite uses them through `src/win32/sprite.zig` so that block-art terminal
content (Claude Code logo, TUI borders, progress bars, etc.) tiles seamlessly
regardless of the user's font metrics.

## Layout

The directory mirrors ghostty's `src/` layout exactly so the original imports
(`../../main.zig`, `../../../quirks.zig`) resolve without modification:

```
ghostty-sprite/
  quirks.zig                      <- src/quirks.zig (just inlineAssert)
  font/
    main.zig                      <- src/font/main.zig (sprite-only adapter)
    Metrics.zig                   <- src/font/Metrics.zig (struct only)
    sprite/
      canvas.zig                  <- src/font/sprite/canvas.zig (writeAtlas removed)
      draw/
        block.zig                 <- src/font/sprite/draw/block.zig (verbatim)
        box.zig                                                     (verbatim)
        braille.zig                                                 (verbatim)
        branch.zig                                                  (verbatim)
        common.zig                                                  (verbatim)
        geometric_shapes.zig                                        (verbatim)
        powerline.zig                                               (verbatim)
        symbols_for_legacy_computing.zig                            (verbatim)
        symbols_for_legacy_computing_supplement.zig                 (verbatim)
```

## Modifications from upstream

Keep modifications minimal so future syncs are mechanical.

- `font/main.zig`: replaced with a sprite-only adapter that exports
  `Metrics` and `sprite.Canvas` (the only symbols draw functions need).
- `font/Metrics.zig`: trimmed to fields only (no `calc`/`apply`/`clamp` that
  pull in `config`/`face`).
- `font/sprite/canvas.zig`: removed `writeAtlas`, `clearClippingRegions`,
  and `font.Atlas` references. Buffer extraction is exposed via a public
  helper. `trim`, `transformation`, drawing primitives are kept verbatim.
- `font/sprite/Face.zig`: NOT vendored; mite has its own minimal dispatcher
  in `src/win32/sprite.zig` that mirrors the comptime range collection.

## License

The vendored code is MIT-licensed by Mitchell Hashimoto and contributors.
See `LICENSE`.
