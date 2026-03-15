# PRD: 2D Pixel-Art Grass System

## Context

The project has a 3D pixel-art grass system using MultiMeshInstance3D + spatial shaders. We want a **2D variant** that works in a 2D scene, using a TileMap for grass placement instead of 3D scatter. The existing 3D code is reference/inspiration only — no existing files will be modified.

## Scope (v1)

**In scope:** Wind animation, view-space oscillation, quantized framerate, cloud shadows, noise-based color patches, accent variants, TileMap-driven placement, fake isometric perspective.
**Out of scope:** Character displacement (future iteration), toon shading (no `Light2D` pipeline in v1).

---

## Rendering Approach: MultiMeshInstance2D

GPUParticles2D is designed for emission/lifetime patterns, not static grid-based placement. MultiMeshInstance2D gives us:
- Precise tile-based positioning via `set_instance_transform_2d()`
- Per-instance custom data for accent seeds
- Single draw call for all grass
- Full `INSTANCE_CUSTOM` access in shader

---

## Scene Architecture (`Scenes/Demo2D.tscn`)

```
Demo2D (Node2D)
├── ShaderGlobals2D (Node)            # Scripts/2D/ShaderGlobals2D.gd (2D-specific cloud params)
├── Camera2D
├── TileMapLayer                      # Ground tiles (Godot 4.4 uses TileMapLayer, not TileMap)
└── GrassSpawner (MultiMeshInstance2D) # Scripts/2D/GrassSpawner.gd
```

### TileMapLayer Setup
- Tile size: set on the TileSet resource (default 96x96 px)
- TileSet with a custom data layer: `"is_grass"` (bool)
- Paint tiles with `is_grass = true` to trigger grass spawning
- Single layer sufficient for v1

---

## Shader Design (`Shaders/2D/Grass2D.gdshader`)

`shader_type canvas_item` — adapted from the 3D `Grass.gdshader`.

### Wind Animation (World-Space)
Same dual-scrolling noise algorithm, using instance world position `.xy` instead of `.xz`:
- Two noise samples diverged at ±`noise_diverge_angle`, scrolled by TIME
- Multiplied together, thresholded, remapped to [-1, 1]
- Applied as **horizontal shear** on `VERTEX.x` proportional to blade height (bottom pinned, top sways)
- Quantized framerate with per-instance phase offset from position-based seed

### View-Space Oscillation
Simple sin-wave sway per blade, same as the 3D `view_sway_speed` / `view_sway_angle` system:
- `sin((time + seed) * view_sway_speed * 2π) * radians(view_sway_angle)`
- Applied as horizontal offset on VERTEX.x, scaled by blade height
- Per-instance phase offset via position-based seed prevents synchronized bobbing
- Adds subtle life independent of wind

### Fake Isometric Perspective
In top-down or isometric 2D games, the Y axis represents both screen-up and depth (Y ≈ Z). When grass sways from wind, a subtle scaling along the Y axis simulates depth — a blade swaying "away" from the camera appears slightly shorter/compressed, giving a pseudo-3D feel without actual 3D transforms.

Applied in fragment shader:
- Subtle `uv.x` compression around center, proportional to `(1.0 - UV.y) * wind_noise_sample * fake_perspective_scale`
- The effect is intentionally subtle — slight narrowing/compression, not dramatic leaning
- Tunable via `fake_perspective_scale` (set to 0 to disable)

### Color Variation
- 3 albedo colors selected by noise threshold (identical to 3D)
- Noise sampled at `world_origin * scale`

### Accent Variants
- `INSTANCE_CUSTOM.xy` carries per-instance random seeds (set by spawner script)
- Same probability-based selection as 3D

### Cloud Shadows
Simplified from 3D: sample noise directly at world position (no ray-plane intersection, no `light_direction`). Applied as `COLOR.rgb *= shadow_value` in `fragment()`.

### Coordinate Scale
3D uses meter-scale (~0.071 noise scale). 2D uses pixel-scale. All noise sampling scales must be adjusted — either use much smaller defaults (~0.001) or normalize world position by dividing by a reference scale before sampling.

---

## Cloud Shadow Include (`Shaders/2D/clouds2d.gdshaderinc`)

Simplified version of `Shaders/clouds.gdshaderinc`:
- Uses **local uniforms** on the ShaderMaterial (not global shader parameters) so 2D and 3D scenes can be tuned independently
- Uniforms: `cloud_noise`, `cloud_scale`, `cloud_speed`, `cloud_contrast`, `cloud_threshold`, `cloud_direction`, `cloud_shadow_min`, `cloud_diverge_angle`
- Does NOT use: `light_direction`, `cloud_world_y` (3D-only)
- Provides: `get_cloud_noise_2d(vec2 world_pos)` and `rotate_vec2()`

---

## ShaderGlobals2D Script (`Scripts/2D/ShaderGlobals2D.gd`)

New `@tool` script (separate from the 3D `ShaderGlobals.gd`) that exposes cloud parameters as `@export` vars and sets them on the GrassSpawner's ShaderMaterial directly, rather than via `RenderingServer.global_shader_parameter_set()`.

### Exports
- `cloud_contrast`, `cloud_direction`, `cloud_diverge_angle`, `cloud_scale`, `cloud_speed`, `cloud_threshold`, `cloud_shadow_min` (same parameter set as 3D, minus `cloud_world_y`)
- `@export var grass_material: ShaderMaterial` — reference to the material to update

### Why not global uniforms?
Global shader parameters are shared across all shaders in the project. If both the 3D and 2D demo scenes exist, changing cloud globals for one breaks the other. Local uniforms on the ShaderMaterial allow independent tuning.

---

## GrassSpawner Script (`Scripts/2D/GrassSpawner.gd`)

`@tool` script on MultiMeshInstance2D.

### Exports
- `tile_map: TileMapLayer` — reference to the TileMapLayer
- `density: int = 6` — grass blades per tile
- `grass_sprite_size: Vector2 = Vector2(16, 24)` — sprite pixel dimensions
- `regenerate: bool` — manual trigger to rebuild (setter calls `_spawn_grass()`)

Note: tile size is read from `tile_map.tile_set.tile_size` at spawn time — no separate export needed.

### Spawn Logic
1. `tile_map.get_used_cells()` → filter by `get_cell_tile_data(cell).get_custom_data("is_grass")`
2. Total instances = `grass_cells.size() * density`
3. Create `MultiMesh` with `TRANSFORM_2D`, `use_custom_data = true`, mesh = `QuadMesh(grass_sprite_size)`
4. For each cell × density index:
   - Position = `tile_map.map_to_local(cell)` + deterministic random offset within tile bounds (inset 90% to avoid edge bleeding)
   - Bottom-anchor offset: shift Y by `-sprite_height / 2`
   - Custom data = `Color(seed1, seed2, 0, 0)` for accent selection
5. Assign shader material

### Determinism
`RandomNumberGenerator` seeded by cell coordinates for consistent placement across editor sessions.

---

## Files to Create

| File | Type | Purpose |
|---|---|---|
| `Shaders/2D/clouds2d.gdshaderinc` | Shader include | 2D cloud shadow sampling (local uniforms) |
| `Shaders/2D/Grass2D.gdshader` | Shader | Core 2D grass canvas_item shader |
| `Scripts/2D/GrassSpawner.gd` | GDScript | TileMap reader + MultiMesh populator |
| `Scripts/2D/ShaderGlobals2D.gd` | GDScript | 2D cloud parameter editor (sets local uniforms) |
| `Scenes/Demo2D.tscn` | Scene | 2D demo scene with all nodes |
| `Textures and Materials/2D/ground_tileset.tres` | TileSet | **Create in Godot editor** — ground tiles with `is_grass` custom data layer |
| `Textures and Materials/2D/ground_tiles.png` | Texture | **Create in Godot editor** — placeholder ground tile atlas (solid color squares) |

## Reused Existing Files (no modifications)

- `Textures and Materials/WindNoise.tres` — wind noise texture
- `Textures and Materials/Albedo2Noise.tres` — color patch noise
- `Textures and Materials/Albedo3Noise.tres` — color patch noise
- `Textures and Materials/Cloud_Noise.tres` — cloud shadow noise (referenced as local uniform default)
- `Textures and Materials/grassleaf.png` — grass blade sprite
- `Textures and Materials/accentleaf.png` — accent sprite

## Implementation Order

1. `clouds2d.gdshaderinc` — dependency for main shader
2. `Grass2D.gdshader` — core visual, test manually first
3. `ShaderGlobals2D.gd` — cloud parameter editor for 2D
4. `GrassSpawner.gd` — tile reading + MultiMesh population
5. `ground_tileset.tres` + `ground_tiles.png` — **create in Godot editor**: TileSet with atlas source and `is_grass` custom data layer
6. `Demo2D.tscn` — assemble scene

## Known Challenges

- **Quad pivot**: QuadMesh centers at (0,0). Offset instance Y by `-sprite_height/2` so blades grow upward from ground.
- **Editor perf**: Use manual `regenerate` trigger, not auto-rebuild on every tile paint.
- **Z-ordering**: All grass at same depth is fine for v1; default painter's order works.
- **No `light()` in v1**: Cloud shadows applied as color multiply in `fragment()`. Toon shading requires `Light2D` nodes (future work).
- **Coordinate scale tuning**: All noise scale defaults need adjusting for pixel coordinates vs 3D meter coordinates.

## Verification

Run the scene from the command line with:
```bash
godot45 --path . Scenes/Demo2D.tscn
```

1. Open `Demo2D.tscn` in Godot 4.4 editor
2. Paint tiles on the TileMapLayer using grass-marked tiles
3. Toggle `regenerate` on GrassSpawner → grass blades appear on painted tiles
4. Run scene → wind animation plays with quantized framerate and per-blade oscillation
5. Verify cloud shadows drift across the grass field
6. Verify noise-based color patches and rare accent variants appear
7. Change `density` export → regenerate → placement adapts correctly
8. Adjust `fake_perspective_scale` → verify UV squishing effect
