# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Godot 4.5 project implementing a stylised 2D pixel-art grass system with wind animation, character-reactive displacement, grass destruction via effector decals, and world-space cloud shadows. Created by Dylearn.

## Running

Open in Godot 4.5+. Main scene: `Scenes/Demo2D.tscn`. No build system — run directly from the Godot editor.

## Architecture

### Shader Pipeline

- **Grass2D.gdshader** — Core 2D grass shader. MultiMesh quads with:
  - Stepped framerate animation (per-instance phase offset to avoid synchronized updates)
  - World-space wind sway via dual scrolling noise textures diverged at an angle
  - Fake perspective UV squishing in fragment
  - Noise-based colour patches (albedo2/albedo3) and accent grass variants selected by instance ID
  - Displacement via terrain data texture (R channel = push, G channel = coverage)
  - Cloud shadows via `clouds2d.gdshaderinc`
- **displacement_gradient.gdshader** — Procedural radial red gradient with additive blend, used as default effector texture

### Scripts (GDScript)

- **GrassChunkManager2D.gd** — Camera-adaptive grass streaming. Pre-computes per-chunk MultiMesh buffers and nav-polygon coverage masks from the TileMapLayer, streams chunks in/out based on camera viewport
- **GrassEffectManager2D.gd** — Manages a SubViewport that renders effector sprites (R channel displacement, G channel coverage masks). Creates mirror sprites for each GrassEffector2D, syncs position/scale/modulate each frame. Supports runtime effector registration via `node_added` signal
- **GrassEffector2D.gd** — Marker script. Add as a child of any Node2D to affect grass. Exports: `effect_texture`, `effect_radius`, `blend_mode` (ADD for displacement, SUB for destruction)
- **ZeldaCamera2D.gd** — Zelda-style camera with grid-quantized scrolling and smooth mousewheel zoom
- **Bomb2D.gd** — Bomb with accelerating pulse animation, spawns crater + particles + camera shake after fuse
- **Crater2D.gd** — Crater decal with GrassEffector2D (SUB). Holds, then fades effector (grass regrows), then fades visual

### Key Conventions

- Grass effectors must be in the `"grass_effectors"` group and expose `effect_texture`, `effect_radius`, and `blend_mode` properties
- Grass uses MultiMeshInstance2D — individual blade transforms are set by Godot's MultiMesh, not by scripts
- Shaders use `group_uniforms` for organized inspector UI

### GDScript Typing Rules

This project treats the "inferred Variant type" warning as a **parse error**. Never use `:=` when the right-hand side returns `Variant`. Common pitfalls:

- `Array.pop_back()`, `Array.pop_front()`, `Array.back()`, `Array.front()` — always return `Variant` even on typed arrays. Use explicit type: `var x: int = arr.pop_back()`
- `Dictionary[key]` — returns `Variant`. Use explicit type: `var x: MyType = dict[key]`
- `for x in [1.0, 2.0]:` — untyped array literals make `x` Variant. Use a typed array: `var arr: Array[float] = [1.0, 2.0]` then `for x in arr:`
- `for key in dict:` / `for key in dict.keys():` — `key` is Variant. Acceptable for iteration but don't use `:=` on expressions derived from it without an explicit type annotation.
- Method chains on `Variant` return `Variant`. E.g. `chunk_manager.get_chunk_map().size()` — even though `.size()` returns `int`, the receiver is `Variant`, so the result is `Variant`. Use explicit type: `var n: int = chunk_manager.get_chunk_map().size()`

## Testing

After any GDScript or shader change, run `timeout 10 godot45 --headless --path . --scene Scenes/Demo2D.tscn 2>&1` to verify no parse or runtime errors. Check for `SCRIPT ERROR`, `Parse Error`, and `Failed to load` in the output.

## Licensing

Code (scripts/shaders): MIT. Art assets: CC BY 4.0 (credit "by Dylearn"). Waterfowl logo: all rights reserved.
