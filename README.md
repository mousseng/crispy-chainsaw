linhud
===============================================================================

a performant HUD that i named after myself because i guess i'm a narcissist.
`xitools` served me very well, but the framerate tax was far too noticeable,
and also it's just tradition that i rewrite my UI every time i start playing
again.

> NOTE: this is still in its slopcode prototype phase, no warranties or
>       refunds. once it's stabilized feature development will probably stop.

i highly recommend including the following binds in your Ashita startup script
if you are a keyboard/mouse player:

```
/bind %I up /linhud inv
/bind %M up /linhud map
/bind %T up /linhud treas
```

usage
-------------------------------------------------------------------------------

there are 6 components currently:

- `party` shows the party (no alliance yet)
- `target` shows your target & subtarget
- `treas` shows the lootpool when there are items in it
- `exp` is your exp bar (docks nicely to top and bottom)
- `inv` is your inventory (off by default)
- `map` is a shitty map overlay (off by default, drag & zoom)

every component supports these commands:

- `/linhud <component> [on|off]`
- `/linhud <component> grow [up|down|left|right|hcenter|vcenter|auto]`
- `/linhud <component> hide [condition] [on|off|default]`
- `/linhud <component> reload`

and some have their own:

- `/linhud exp width [n]`
- `/linhud party status [n]` - how many lines of buffs to show (0 hides them)
- `/linhud target demo` - fakes a skillchain on your target (mostly for testing)
- `/linhud treas demo` - toggle a fake pool to try the panel out solo
- `/linhud treas clock` - what's known about the server's pool clock
- `/linhud map size|zoom|marker [n]` - map size (128-2048), zoom (1-8), marker scale (0.5-4)
- `/linhud map opacity [still] [moving]` - opacity while standing and while moving (0-1)
- `/linhud map info`
- `/linhud inv columns|rows [n]` - configure the inventory grid size
- `/linhud inv unified [on|off]` - one sorted grid per tab, or a heading and grid per bag

### general

- `/linhud list` - show the toggle state of each comonent
- `/linhud unlock` / `/linhud lock` - toggles drag-and-drop positioning of components
- `/linhud hide [condition] [on|off]` - which client states hide the hud
  - `loading`
  - `event`
  - `interface`
  - `map`
  - `chat`
- `/linhud state` - which of those states the client is in right now
- `/linhud theme [name]` - show or switch the theme
- `/linhud scale <n>` - ui scale, 0.5-4

### diagnostics

- `/linhud stats` - renderer cost: quads, draw calls, frame time, jit aborts, icon cache
- `/linhud jit` - write the code luajit couldn't compile, and why, to a file
- `/linhud quads` - write the last frame's quads and glyph metrics to a file
- `/linhud dump [icons|status]` - save the theme atlas (or an icon atlas) as a png

TODO
-------------------------------------------------------------------------------
1. alliance panels (preferably condensed raid frames, like ffxiv)
2. pet panel (i don't have one of those to test with yet)

