crispy chainsaw
===============================================================================

a performant HUD. why `crispy-chainsaw`? github recommended it when i was
preparing to publish, and i thought it was funny. truly inspired stuff from
microsoft.

`xitools` served me very well, but the framerate tax was far too noticeable,
and also it's just tradition that i rewrite my UI every time i start playing
again.

> NOTE: this is still in its slopcode prototype phase, no warranties or
>       refunds. once it's stabilized feature development will probably stop.

i highly recommend including the following binds in your Ashita startup script
if you are a keyboard/mouse player:

```
/bind %I up /cc inv
/bind %M up /cc map
/bind %T up /cc treas
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

- `/cc <component> [on|off]`
- `/cc <component> grow [up|down|left|right|hcenter|vcenter|auto]`
- `/cc <component> hide [condition] [on|off|default]`
- `/cc <component> reload`

and some have their own:

- `/cc exp width [n]`
- `/cc party status [n]` - how many lines of buffs to show (0 hides them)
- `/cc target demo` - fakes a skillchain on your target (mostly for testing)
- `/cc treas demo` - toggle a fake pool to try the panel out solo
- `/cc treas clock` - what's known about the server's pool clock
- `/cc map size|zoom|marker [n]` - map size (128-2048), zoom (1-8), marker scale (0.5-4)
- `/cc map opacity [still] [moving]` - opacity while standing and while moving (0-1)
- `/cc map info`
- `/cc inv columns|rows [n]` - configure the inventory grid size
- `/cc inv unified [on|off]` - one sorted grid per tab, or a heading and grid per bag

### general

- `/cc list` - show the toggle state of each comonent
- `/cc unlock` / `/linhud lock` - toggles drag-and-drop positioning of components
- `/cc hide [condition] [on|off]` - which client states hide the hud
  - `loading`
  - `event`
  - `interface`
  - `map`
  - `chat`
- `/cc state` - which of those states the client is in right now
- `/cc theme [name]` - show or switch the theme
- `/cc scale <n>` - ui scale, 0.5-4

### diagnostics

- `/cc stats` - renderer cost: quads, draw calls, frame time, jit aborts, icon cache
- `/cc mem [gc]` - memory: lua heap, garbage per frame, our textures, the game process' address space; `gc` runs a full collection first; `prof [frames]` charges each frame's allocations to source lines (top lines in chat, full list in memprof.txt)
- `/cc jit` - write the code luajit couldn't compile, and why, to a file
- `/cc quads` - write the last frame's quads and glyph metrics to a file
- `/cc dump [icons|status]` - save the theme atlas (or an icon atlas) as a png

TODO
-------------------------------------------------------------------------------
1. alliance panels (preferably condensed raid frames, like ffxiv)
2. pet panel (i don't have one of those to test with yet)

