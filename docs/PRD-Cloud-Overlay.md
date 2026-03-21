# PRD: Cloud Overlay Extraction & Effector Refactor

## Context

Cloud shadows currently live inside `Grass2D.gdshader` and only darken grass blades. They should affect the entire scene (sprites, tiles, grass). This requires extracting cloud rendering into a separate full-screen overlay node. Additionally, the effector system needs refactoring: `GrassEffector2D` should extend `Sprite2D` (using native texture/transform instead of the `effect_radius` abstraction), and support writing to any SubViewport channel via `target_channel` + `blend_operation` exports. This unlocks using the A channel for cloud immunity and B channel for pseudo-3D cloud Y-offset.

## Channel Map (terrain_data SubViewport)

| Channel | Purpose | Blend | Consumer |
|---------|---------|-------|----------|
| R | Displacement strength | ADD | Grass2D.gdshader vertex |
| G | Grass coverage mask | meshes + SUB | Grass2D.gdshader vertex |
| B | Cloud Y-offset (pseudo-3D) | ADD | cloud_overlay.gdshader fragment |
| A | Cloud immunity | ADD | cloud_overlay.gdshader fragment |

---

## Phase A: New Files (additive, no breakage)

### A1. `Shaders/2D/effector_channel.gdshader`

Single channel-routing shader using `render_mode blend_disabled` + `hint_screen_texture`. Reads the current framebuffer, modifies only the target channel, writes back directly. Handles both ADD and SUB via a `subtract_mode` uniform. No fixed-function blend modes — full per-channel independence including alpha.

Requires a `BackBufferCopy` node before each effector in the SubViewport tree so overlapping effectors accumulate correctly (screen texture is only copied when a BackBufferCopy is encountered).

```glsl
shader_type canvas_item;
render_mode blend_disabled;

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform int target_channel : hint_range(0, 3) = 0;
uniform bool subtract_mode = false;

void fragment() {
    vec4 screen = texture(screen_texture, SCREEN_UV);
    float value = texture(TEXTURE, UV).r * COLOR.a;

    float delta = value;
    if (subtract_mode) delta = -value;

    if (target_channel == 0) screen.r += delta;
    else if (target_channel == 1) screen.g += delta;
    else if (target_channel == 2) screen.b += delta;
    else screen.a += delta;

    COLOR = clamp(screen, vec4(0.0), vec4(1.0));
}
```

### A2. `Shaders/2D/mask_coverage.gdshader`

Simple shader for coverage mask MeshInstance2D nodes. Uses `render_mode blend_premul_alpha` with alpha=0 output — this gives true additive blending (`src + dst` when alpha=0) so G=1 is added without touching the A channel. Masks don't overlap (chunk-based nav polygons), so no BackBufferCopy needed between them.

```glsl
shader_type canvas_item;
render_mode blend_premul_alpha;

void fragment() {
    COLOR = vec4(0.0, 1.0, 0.0, 0.0);
}
```

### A3. `Shaders/2D/cloud_overlay.gdshader`

Full-screen cloud shadow shader using `render_mode blend_mul`. Outputs `vec4(cloud_val, cloud_val, cloud_val, 1.0)` — multiplication darkens the scene.

- Cloud uniforms: same 9 params currently in Grass2D.gdshader lines 9-17
- `#include "res://Shaders/2D/clouds2d.gdshaderinc"` — reuses existing algorithm
- Camera uniforms: `camera_position` (vec2), `camera_zoom` (vec2) — set per frame by script
- Terrain uniforms: `terrain_data_texture`, `terrain_bounds`, `cloud_y_offset_scale` (float, default 50)

Fragment logic:
1. Convert `SCREEN_UV` to world position: `world_pos = (SCREEN_UV - 0.5) * screen_size / camera_zoom + camera_position` where `screen_size = 1.0 / SCREEN_PIXEL_SIZE`
2. Compute terrain UV from `terrain_bounds`, sample `terrain_data_texture`:
   - `immunity = terrain.a` (0 = full cloud effect, 1 = immune)
   - `y_offset = terrain.b * cloud_y_offset_scale`
3. Offset cloud sampling: `cloud_pos.y -= y_offset`
4. `cloud_val = get_cloud_noise_2d(cloud_pos)`
5. Apply immunity: `cloud_val = mix(cloud_val, 1.0, immunity)`
6. Output: `vec4(cloud_val, cloud_val, cloud_val, 1.0)`
7. If `!cloud_shadows_enabled`, output `vec4(1.0)` (no darkening)

### A4. `Scripts/2D/CloudOverlay2D.gd`

`@tool` script extending `Node`. Creates CanvasLayer + full-screen ColorRect at runtime.

Exports:
- `camera: Camera2D`
- `effect_manager: Node` — reference to GrassEffectManager2D
- `cloud_material: ShaderMaterial` — the cloud_overlay material
- `canvas_layer_index: int = 1`

`_ready()`:
1. Create CanvasLayer (layer = canvas_layer_index)
2. Create ColorRect child, anchored full-screen, assigned cloud_material, `mouse_filter = IGNORE`
3. After deferred frames (matching GrassEffectManager2D init), bind `terrain_data_texture` from the grass material to the cloud material

`_process()`:
1. Set `camera_position` and `camera_zoom` uniforms from camera
2. Read `terrain_bounds` from grass material, sync to cloud material

### A5. `Textures and Materials/cloud_overlay_material.tres`

ShaderMaterial pointing to `cloud_overlay.gdshader`. Copy cloud parameter values from current `grass_2d_material.tres`:
- cloud_shadows_enabled = true
- cloud_noise = Cloud_Noise.tres
- cloud_scale = 2000.0, cloud_speed = 0.01, cloud_contrast = 3.845
- cloud_threshold = 0.27, cloud_direction = Vector2(-1, 0)
- cloud_shadow_min = 0.2, cloud_diverge_angle = 10.0

### A6. Convert `crater_gras_mask.png` from green to white/grayscale

The channel-routing shader samples `.r` from the texture. Current crater mask is green (R=0, G=255). Convert so mask data is in all channels (white: R=G=B=255 where solid, 0 where empty). This makes it work with `.r` sampling and looks natural as a Sprite2D texture in the editor.

---

## Phase B: Effector System Refactor

### B1. Rewrite `Scripts/2D/GrassEffector2D.gd`

Change from `extends Node2D` to `extends Sprite2D`.

Remove exports: `effect_texture`, `effect_radius`, `blend_mode`

Add exports:
- `target_channel: int` via `@export_enum("R:0", "G:1", "B:2", "A:3")` — default 0
- `blend_operation: int` via `@export_enum("ADD:0", "SUB:1")` — default 0

`_ready()`:
- `add_to_group("grass_effectors")`
- If runtime (not editor): `visible = false` — effector is data-only at runtime, visible in editor for authoring

~12 lines total.

### B2. Modify `Scripts/2D/GrassEffectManager2D.gd`

**Remove:**
- `_gradient_shader`, `_default_texture`, `DEFAULT_SPRITE_SIZE` members
- `_apply_scale()` function
- `tex_size` from mirror dict entries
- Gradient shader loading and placeholder texture creation in `_ready()`

**Add:**
- `_channel_shader: Shader` — single effector_channel.gdshader
- `_mask_shader: Shader` — mask_coverage.gdshader
- Load both in `_ready()`

**Update `_create_mask_pool()`:**
- Create a `ShaderMaterial` from `_mask_shader` and assign to each MeshInstance2D
- Remove `mi.modulate = Color(0, 1, 0, 1)` — the shader handles G=1 output directly
- Add one `BackBufferCopy` node (COPY_MODE_VIEWPORT) after all masks, before effectors

**Rewrite `_add_mirror()`:**
- Read `effector.texture` (Sprite2D native property) instead of `effector.effect_texture`
- If no texture: `push_warning()` and return
- Read `target_channel` and `blend_operation` from effector
- Add a `BackBufferCopy` node (COPY_MODE_VIEWPORT) before the mirror sprite
- Create `ShaderMaterial` from `_channel_shader`
- Set `target_channel` and `subtract_mode` uniforms on the material
- Copy `effector.global_transform` to mirror
- Dict entry: `{source = effector, mirror = mirror, bbc = bbc}` (BackBufferCopy ref for cleanup)

**Rewrite mirror sync in `_process()`:**
```gdscript
for entry in _mirror_sprites:
    var source: Node2D = entry.source
    var mirror: Sprite2D = entry.mirror
    mirror.global_transform = source.global_transform
    mirror.modulate = source.modulate
```

No more `effect_radius` check or `_apply_scale` call.

**Mirror cleanup** must also free the associated `BackBufferCopy` node when a source effector is freed.

### B3. Update `Scenes/Demo2D.tscn` — character effector

Current (line 473-477):
```
[node name="GrassEffector2D" type="Node2D" parent="Sprite2D"]
position = Vector2(0, 7)
script = ExtResource("13_displacer")
effect_texture = ExtResource("14_gb8of")
effect_radius = 16.0
```

New:
```
[node name="GrassEffector2D" type="Sprite2D" parent="Sprite2D"]
position = Vector2(0, 7)
scale = Vector2(2, 2)
script = ExtResource("13_displacer")
texture = ExtResource("14_gb8of")
target_channel = 0
blend_operation = 0
```

`displace.png` is 16x16, red radial gradient. Old radius=16, old scale = 16/(16/2) = 2.0. So `scale = Vector2(2, 2)`. Data is already in R channel.

### B4. Update `Scenes/Crater.tscn` — crater effector

Current (line 15-19):
```
[node name="GrassEffector2D" type="Node2D" parent="."]
script = ExtResource("4_effector")
effect_texture = ExtResource("3_mask")
effect_radius = 24.0
blend_mode = 2
```

New:
```
[node name="GrassEffector2D" type="Sprite2D" parent="."]
script = ExtResource("4_effector")
texture = ExtResource("3_mask")
target_channel = 1
blend_operation = 1
```

crater_gras_mask.png is ~48x48 (after A6 conversion to white). Old radius=24, old scale = 24/(48/2) = 1.0. Default scale is fine.

**No changes needed to `Crater2D.gd`** — `_effector: Node2D` is still valid (Sprite2D extends Node2D), and `modulate:a` tween works the same.

### B5. Delete `Shaders/2D/displacement_gradient.gdshader` (and its .uid file)

No longer referenced. Replaced by texture + channel-routing shader approach.

---

## Phase C: Cloud Extraction

### C1. Strip cloud code from `Shaders/2D/Grass2D.gdshader`

Remove:
- Lines 7-17: cloud uniform declarations (11 lines)
- Line 19: `#include "res://Shaders/2D/clouds2d.gdshaderinc"`
- Lines 246-249: cloud shadow application in fragment

**Critical:** `rotate_vec2()` from the include is used at lines 143-144 for wind direction divergence. Copy the function (5 lines from `clouds2d.gdshaderinc` lines 6-11) inline into `Grass2D.gdshader`, placed before `vertex()`.

### C2. Clean `Textures and Materials/grass_2d_material.tres`

Remove cloud shader_parameter lines (cloud_shadows_enabled, cloud_noise, cloud_scale, cloud_speed, cloud_contrast, cloud_threshold, cloud_direction, cloud_shadow_min, cloud_diverge_angle). Best done via Godot editor re-save after shader change.

### C3. Add CloudOverlay2D to `Scenes/Demo2D.tscn`

Add as last child of root:
```
[node name="CloudOverlay2D" type="Node" parent="."]
script = CloudOverlay2D.gd
camera = NodePath("../Camera2D")
effect_manager = NodePath("../GrassEffectManager2D")
cloud_material = cloud_overlay_material.tres
canvas_layer_index = 1
```

### C4. `Shaders/2D/clouds2d.gdshaderinc` — no changes

Now only included by `cloud_overlay.gdshader`. Still works as-is.

---

## Files Summary

| File | Action |
|------|--------|
| `Shaders/2D/effector_channel.gdshader` | Create (blend_disabled + screen_texture) |
| `Shaders/2D/mask_coverage.gdshader` | Create (blend_premul_alpha, G-only) |
| `Shaders/2D/cloud_overlay.gdshader` | Create |
| `Scripts/2D/CloudOverlay2D.gd` | Create |
| `Textures and Materials/cloud_overlay_material.tres` | Create |
| `Textures and Materials/crater_gras_mask.png` | Modify (green -> white) |
| `Scripts/2D/GrassEffector2D.gd` | Rewrite |
| `Scripts/2D/GrassEffectManager2D.gd` | Modify |
| `Scenes/Demo2D.tscn` | Modify (effector + CloudOverlay2D) |
| `Scenes/Crater.tscn` | Modify (effector type/props) |
| `Shaders/2D/displacement_gradient.gdshader` | Delete |
| `Shaders/2D/Grass2D.gdshader` | Modify (remove cloud, add rotate_vec2) |
| `Textures and Materials/grass_2d_material.tres` | Modify (remove cloud params) |
| `CLAUDE.md` | Update architecture docs |

**Unchanged:** `clouds2d.gdshaderinc`, `Crater2D.gd`, `Bomb2D.gd`, `ZeldaCamera2D.gd`, `GrassChunkManager2D.gd`

---

## Verification

After each phase, run:
```bash
timeout 10 godot45 --headless --path . --scene Scenes/Demo2D.tscn 2>&1
```
Check for `SCRIPT ERROR`, `Parse Error`, `Failed to load`.

Manual testing:
- **Phase B**: Character displacement still works, bomb craters still destroy + regrow grass
- **Phase C**: Cloud shadows darken entire scene (sprites + tiles + grass), not just grass. No double-darkening on grass.
- **A+B channels**: Place test effectors with target_channel=A (cloud immunity) and target_channel=B (Y-offset) to verify cloud overlay reads them correctly
