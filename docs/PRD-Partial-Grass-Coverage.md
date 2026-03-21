# PRD: Partial Grass Coverage via Navigation Polygons

## Context

The 2D grass system (see `PRD-Camera-Adaptive-Grass.md`) currently spawns grass on a tile-by-tile basis: a tile either has grass (`is_grass=true`) or doesn't. This creates hard edges at tile boundaries — paths, cliff edges, shorelines, and other terrain transitions can't have grass that partially covers a tile.

We need per-tile partial grass coverage. The approach: repurpose a TileSet **navigation layer** as a "grass coverage polygon" that defines where grass grows within each tile. The polygon data is rendered into the terrain data texture's **G channel** (reserved for this purpose since `PRD-Terrain-Data-Texture.md`), and the shader scales blade vertices based on G value.

## Scope

**v1 (this PRD):** Navigation polygon grass masks rendered into G channel, blade scale controlled by shader.

**Out of scope:** Smooth density gradients (G is binary — inside/outside polygon), foliage type selection (B channel), procedural edge feathering.

---

## Architecture Overview

```
TileSet
├── Custom Data Layer 0: "is_grass" (bool)
├── Navigation Layer 0: standard pathfinding (if any)
└── Navigation Layer 0: "grass coverage" polygons     # NEW — defines where grass grows

Demo2D (Node2D)
├── Camera2D
├── TileMapLayer (tile data includes navigation polygons)
├── GrassChunkManager2D (Node2D)
│   └── pool of MultiMeshInstance2D
│
├── DisplacementManager2D (Node)                       # MODIFIED
│   └── SubViewport
│       ├── Camera2D (tracks game camera)
│       ├── GrassMaskControl (Control)                 # NEW — draws nav polygons as green fills
│       └── [mirror sprites for displacement — red, additive]
│
└── Character
    └── GrassDisplacer2D
```

### Data Flow

1. At startup, `DisplacementManager2D` reads navigation polygons from the TileMapLayer for all grass tiles
2. Each frame, `GrassMaskControl._draw()` renders the visible navigation polygons as green filled triangles into the SubViewport
3. Displacement sprites render on top with additive blend (red channel only)
4. Result texture: **R = displacement strength, G = grass coverage**
5. `Grass2D.gdshader` samples G at each blade's world position and scales `VERTEX` accordingly

### Why This Works with the Existing SubViewport

The displacement SubViewport renders per-frame with `transparent_bg = true` (clears to RGBA 0,0,0,0):

1. **GrassMaskControl** draws green filled polygons → pixels become **(0, 1, 0, 1)** inside polygons
2. **Displacement sprites** draw red gradients with `blend_add` → pixels become **(R, 1, 0, 1)**

Displacement sprites use additive blending and write **only to R** (green component = 0 in the sprite textures). The G channel from the grass mask is preserved. Single texture, single UV system — no second viewport needed.

---

## TileSet Configuration

### Adding the Navigation Layer

Add a **Navigation Layer** to the TileSet dedicated to grass coverage. The layer index is configurable (default 0). If the project also uses navigation for pathfinding, use separate layer indices.

The layer index is configurable via an export on DisplacementManager2D:

```gdscript
@export var grass_nav_layer: int = 0  # Navigation layer index used for grass coverage
```

### Per-Tile Polygon Editing

In the TileSet editor:
1. Select a grass tile
2. Switch to the Navigation tab, select the grass coverage layer
3. Draw a polygon defining where grass grows within that tile
4. The polygon uses the same editor UI as standard navigation polygons — click to add vertices, drag to adjust

### Default Full-Tile Coverage

Tiles with `is_grass=true` but **no navigation polygon** on the grass coverage layer default to **full-tile coverage** — the runtime generates a full-tile rectangle automatically. This means existing tilemaps work unchanged; partial coverage is opt-in per tile.

---

## Rendering into G Channel

### GrassMaskControl

A `Control` node added as a child of the displacement SubViewport. It renders **before** the displacement sprites (earlier in node order = drawn first).

```gdscript
# Created by DisplacementManager2D in _ready()
var _mask_control: Control

func _create_grass_mask() -> void:
    _mask_control = Control.new()
    _mask_control.set_anchors_preset(Control.PRESET_FULL_RECT)
    _mask_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _mask_control.connect("draw", _draw_grass_mask)
    _viewport.add_child(_mask_control)
    # Move to front of children so it renders BEFORE displacement sprites
    _viewport.move_child(_mask_control, 0)
```

### Drawing Logic

Each frame, `_draw_grass_mask()` iterates visible grass tiles and draws their navigation polygons as green filled triangles:

```gdscript
func _draw_grass_mask() -> void:
    var tile_map: TileMapLayer = chunk_manager.tile_map
    var tile_size := Vector2(tile_map.tile_set.tile_size)
    var half_tile := tile_size / 2.0
    var green := Color(0, 1, 0, 1)
    var green_arr := PackedColorArray([green])

    for cell in _get_visible_grass_cells():
        var data := tile_map.get_cell_tile_data(cell)
        if not data:
            continue

        var world_pos := tile_map.map_to_local(cell)
        var nav_poly: NavigationPolygon = data.get_navigation_polygon(grass_nav_layer)

        if nav_poly and nav_poly.get_polygon_count() > 0:
            # Tile has a custom grass coverage polygon
            var verts := nav_poly.get_vertices()
            for poly_idx in nav_poly.get_polygon_count():
                var indices := nav_poly.get_polygon(poly_idx)
                var tri := PackedVector2Array()
                for idx_i in indices.size():
                    var vi: int = indices[idx_i]
                    tri.append(verts[vi] + world_pos)
                _mask_control.draw_colored_polygon(tri, green)
        else:
            # No polygon — default to full tile coverage
            var rect_verts := PackedVector2Array([
                world_pos + Vector2(-half_tile.x, -half_tile.y),
                world_pos + Vector2( half_tile.x, -half_tile.y),
                world_pos + Vector2( half_tile.x,  half_tile.y),
                world_pos + Vector2(-half_tile.x,  half_tile.y),
            ])
            _mask_control.draw_colored_polygon(rect_verts, green)
```

### Visible Cell Determination

The mask only needs to draw cells within the SubViewport's coverage area (camera position ± world_size/2). This can reuse the active zone computation from `GrassChunkManager2D`, or simply iterate the chunk manager's active chunks:

```gdscript
func _get_visible_grass_cells() -> Array[Vector2i]:
    return chunk_manager.get_active_grass_cells()
```

This calls a new public method on `GrassChunkManager2D`:

```gdscript
func get_active_grass_cells() -> Array[Vector2i]:
    var cells: Array[Vector2i] = []
    for chunk_key in _active_chunks:
        var chunk: ChunkData = _chunk_map[chunk_key]
        cells.append_array(chunk.grass_cells)
    return cells
```

### Redraw Trigger

`_mask_control.queue_redraw()` is called each frame in `DisplacementManager2D._process()` — the viewport already re-renders every frame for displacement tracking, so the grass mask redraws are free.

---

## Shader Changes

### Grass2D.gdshader — Vertex Shader

Inside the existing `if (displacement_enabled)` block, after the R channel displacement code (line 193) and still within the terrain UV bounds check, add G channel sampling:

```glsl
// Inside the existing displacement block, after the push_dir displacement code:

// G channel: grass coverage mask
float grass_density = texture(terrain_data_texture, terrain_uv).g;
VERTEX *= grass_density;  // Scale entire blade — 0 = invisible, 1 = full size
```

Add an `else` clause to the existing bounds check to hide blades outside the terrain data texture coverage:

```glsl
} else {
    // Outside terrain bounds — no coverage data available, hide blade
    VERTEX *= 0.0;
}
```

This reuses the already-computed `terrain_uv` from the displacement block — no duplicated UV computation.

**Key design choice: blade scale only.** All grass instances still spawn (chunk buffers unchanged). The G channel controls vertex scale:
- `G = 0.0` → blade collapsed to a point (invisible)
- `G = 1.0` → blade at full size
- Intermediate values produce smooth size transitions at polygon edges (due to texture filtering)

This keeps the chunk system completely unchanged — no buffer recomputation when the mask changes. The mask is purely a real-time shader effect.

### Why Not Discard in Fragment?

Scaling `VERTEX` to zero in the vertex shader is more efficient than `discard` in fragment:
- No fragment shader execution for invisible blades
- No alpha testing overhead
- Smooth transitions via texture filtering on the G channel boundary

---

## DisplacementManager2D Changes

### New Exports

```gdscript
@export var grass_nav_layer: int = 0  # Navigation layer index for grass coverage polygons
```

### Modified `_ready()`

After creating the SubViewport and internal camera, create the `GrassMaskControl` **before** the displacement mirror sprites:

```gdscript
# Create grass mask control (renders nav polygons as green fills)
_create_grass_mask()

# Then create displacement mirror sprites (render red gradients with additive blend)
for displacer in get_tree().get_nodes_in_group("grass_displacers"):
    _add_mirror(displacer)
```

### Modified `_process()`

Add `queue_redraw()` for the mask control (alongside existing mirror sync):

```gdscript
if _mask_control:
    _mask_control.queue_redraw()
```

---

## Navigation Polygon Coordinate Space

Navigation polygon vertices from `TileData.get_navigation_polygon()` are in **tile-local space** — relative to the tile's origin (center). To convert to world space for rendering:

```gdscript
var world_vertex := nav_poly_vertex + tile_map.map_to_local(cell)
```

The SubViewport's Camera2D maps world coordinates to viewport pixels, so world-space vertices render at the correct positions automatically.

---

## Editor Workflow

### Setting Up Partial Grass

1. Open the TileSet in the inspector
2. Add a Navigation Layer (if not already present)
3. For each tile that needs partial grass:
   - Select the tile in the TileSet atlas
   - Switch to the Navigation panel
   - Select the grass coverage navigation layer
   - Draw a polygon defining the grass area
4. Tiles without a polygon default to full coverage — no action needed for fully-grassed tiles

### Visual Feedback

In the editor, the navigation polygon is visible as an overlay on the tile. This gives immediate visual feedback about grass coverage while editing the TileSet.

At runtime with `debug_overlay` enabled on `GrassChunkManager2D`, the grass mask polygons are implicitly visible through the grass density changes.

---

## Performance

### Rendering Cost

- **Polygon count**: ~200-300 triangles per frame (2-4 triangles per tile × ~60-80 visible tiles)
- **`draw_colored_polygon()`**: Batched by Godot's 2D renderer; flat-color fills are very cheap
- **No texture sampling**: Polygons are solid green — no texture binds, no UV computation
- **Already in SubViewport**: No additional render passes; the displacement viewport already re-renders every frame

### Shader Cost

- **One additional texture sample** per blade: `texture(terrain_data_texture, terrain_uv).g`
- Already sampling R for displacement — the G read is essentially free (same texel fetch, different swizzle)
- `VERTEX *= grass_density` is one multiply — negligible

---

## Edge Cases

### Tiles with `is_grass=false`

These tiles don't generate grass instances in `GrassChunkManager2D`, so no mask polygon is drawn. The G channel stays 0 for these areas, but no blades exist to sample it.

### Tiles at Map Edges

The SubViewport's Camera2D covers the viewport + `displacement_buffer` padding. Tiles partially within this area still have their polygons drawn. Tiles entirely outside are skipped by the visible cell iteration.

### Smooth Transitions at Polygon Edges

The G channel boundary between inside (1.0) and outside (0.0) is razor-sharp in a single `draw_colored_polygon()` call. However, the SubViewport texture is sampled with bilinear filtering, so blades near the polygon edge will see intermediate G values (0.0–1.0), producing a natural fade-out. The viewport resolution (512×512) controls how many world pixels this transition spans.

### Multiple Polygons per Tile

Navigation polygons support multiple outlines and are triangulated via `make_polygons_from_outlines()`. Complex shapes (holes, concave polygons) are handled automatically by Godot's polygon triangulation.

### Displacement + Density Interaction

A blade at the edge of a displacement zone AND at the edge of a grass coverage polygon receives both effects: it scales down from G channel AND shears from R channel. This produces natural-looking results — partially-hidden blades that also lean away from displacers.

### Displacement Texture Convention

Displacement textures (both `displace.png` and the procedural `displacement_gradient.gdshader`) must only write to the **R channel** (G=0, B=0). The existing textures already follow this. Custom displacement textures with non-zero green would corrupt the grass mask by adding to the G channel via additive blend.

### `displacement_enabled` Guards Both Features

The `displacement_enabled` shader uniform controls both displacement (R channel) and grass masking (G channel). Disabling it disables both. This is intentional — the terrain data texture is an all-or-nothing system.

---

## Files Changed

| File | Action | Notes |
|------|--------|-------|
| `Scripts/2D/DisplacementManager2D.gd` | **Modify** | Add GrassMaskControl, `grass_nav_layer` export, draw logic |
| `Scripts/2D/GrassChunkManager2D.gd` | **Modify** | Add `get_active_grass_cells()` public method |
| `Shaders/2D/Grass2D.gdshader` | **Modify** | Sample G channel, scale VERTEX, add else clause for out-of-bounds |
| `Scenes/Demo2D.tscn` | **Modify** | Add navigation layer to TileSet, draw test polygons on a few tiles |

---

## Implementation Sequence

1. **TileSet**: Add a navigation layer to the TileSet in Demo2D.tscn. Draw test polygons on 2-3 grass tiles (half-coverage, diagonal, L-shape).
2. **Shader**: Add G channel sampling and `VERTEX *= grass_density` after the displacement block in Grass2D.gdshader.
3. **DisplacementManager2D**: Add `GrassMaskControl` that renders navigation polygons as green fills into the SubViewport. Add `grass_nav_layer` export.
4. **Test**: Run scene, verify partial grass tiles show grass only within the polygon area. Verify full-coverage tiles (no polygon) still have full grass. Verify displacement still works alongside the mask.
5. **Tune**: Adjust viewport resolution if transitions are too sharp or too blurry.

---

## Verification

1. **Partial tile**: Draw a half-tile polygon on a grass tile. Grass should appear only on the polygon half.
2. **Full tile default**: Tiles with `is_grass=true` but no polygon should have full grass (unchanged from current).
3. **No grass tile**: Tiles with `is_grass=false` should show no grass regardless of polygons.
4. **Displacement still works**: Move character through partially-grassed area. Blades still shear away.
5. **Camera scrolling**: Pan the camera. Partial grass tiles stream in/out correctly via the chunk system.
6. **Complex polygon**: Draw an L-shaped or concave polygon on a tile. Grass should respect the shape.
7. **Adjacent tiles**: Two adjacent tiles with different polygon shapes should have seamless grass at their shared edge (where both have coverage) and a clean cutoff where coverage differs.
