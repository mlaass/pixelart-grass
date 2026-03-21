# MIT License.
# Made by Dylearn

# Manages a SubViewport that renders displacement sprites for each
# GrassDisplacer2D node, then binds the resulting texture to the grass
# shader so blades shear away from nearby displacers.
# The viewport follows the game camera so displacement works at any
# camera position without covering the entire map.

@tool
extends Node

@export var chunk_manager: Node
@export var camera: Camera2D
@export var viewport_resolution: Vector2i = Vector2i(512, 512)
@export var displacement_buffer: float = 128.0

const DEFAULT_SPRITE_SIZE := 64

var _viewport: SubViewport
var _internal_cam: Camera2D
var _mirror_sprites: Array[Dictionary] = []
var _gradient_shader: Shader
var _default_texture: PlaceholderTexture2D
var _additive_mat: CanvasItemMaterial
var _grass_material: ShaderMaterial


func _ready() -> void:
	if not chunk_manager or not "grass_material" in chunk_manager:
		return
	_grass_material = chunk_manager.grass_material
	if not _grass_material:
		return
	if not camera:
		return

	# Create SubViewport
	_viewport = SubViewport.new()
	_viewport.size = viewport_resolution
	_viewport.transparent_bg = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	# Camera2D — positioned dynamically in _process()
	_internal_cam = Camera2D.new()
	_viewport.add_child(_internal_cam)

	# Additive blend material for custom-texture displacers
	_additive_mat = CanvasItemMaterial.new()
	_additive_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD

	# Default gradient shader + placeholder for displacers without a texture
	_gradient_shader = load("res://Shaders/2D/displacement_gradient.gdshader")
	_default_texture = PlaceholderTexture2D.new()
	_default_texture.size = Vector2(DEFAULT_SPRITE_SIZE, DEFAULT_SPRITE_SIZE)

	# Defer displacer discovery so all nodes have finished _ready() and joined groups
	await get_tree().process_frame

	# Create mirror sprites for all displacers
	for displacer in get_tree().get_nodes_in_group("grass_displacers"):
		_add_mirror(displacer)

	# Wait another frame so the viewport texture is valid
	await get_tree().process_frame

	# Bind viewport texture to grass material
	_grass_material.set_shader_parameter("terrain_data_texture", _viewport.get_texture())
	_grass_material.set_shader_parameter("displacement_enabled", true)


func _process(_delta: float) -> void:
	if not camera or not _internal_cam or not _grass_material:
		return

	# Compute world-space coverage for the displacement viewport
	var viewport_size := get_viewport().get_visible_rect().size
	var world_size := viewport_size / camera.zoom + Vector2(displacement_buffer * 2.0, displacement_buffer * 2.0)

	# Track game camera
	_internal_cam.position = camera.global_position
	_internal_cam.zoom = Vector2(viewport_resolution) / world_size

	# Update terrain_bounds uniform so the shader computes correct UVs
	var half_world := world_size / 2.0
	var bounds_min := camera.global_position - half_world
	var bounds_max := camera.global_position + half_world
	_grass_material.set_shader_parameter("terrain_bounds", Vector4(
		bounds_min.x, bounds_min.y, bounds_max.x, bounds_max.y
	))

	# Sync mirror sprite positions
	for entry in _mirror_sprites:
		var source: Node2D = entry.source
		var mirror: Sprite2D = entry.mirror
		if not is_instance_valid(source):
			continue
		mirror.position = source.global_position
		if "displacement_radius" in source:
			var radius: float = source.displacement_radius
			_apply_scale(mirror, entry.tex_size, radius)


func _add_mirror(displacer: Node) -> void:
	var mirror := Sprite2D.new()
	var tex: Texture2D = displacer.displacement_texture if "displacement_texture" in displacer else null
	var tex_size: float

	if tex:
		# Custom texture — use CanvasItemMaterial for additive blend
		mirror.texture = tex
		mirror.material = _additive_mat
		tex_size = tex.get_size().x
	else:
		# No texture — use procedural gradient shader (has blend_add built in)
		mirror.texture = _default_texture
		var gradient_mat := ShaderMaterial.new()
		gradient_mat.shader = _gradient_shader
		mirror.material = gradient_mat
		tex_size = DEFAULT_SPRITE_SIZE

	mirror.position = displacer.global_position
	var radius: float = displacer.displacement_radius if "displacement_radius" in displacer else 64.0
	_apply_scale(mirror, tex_size, radius)
	_viewport.add_child(mirror)
	_mirror_sprites.append({source = displacer, mirror = mirror, tex_size = tex_size})


func _apply_scale(mirror: Sprite2D, tex_size: float, radius: float) -> void:
	mirror.scale = Vector2.ONE * radius / (tex_size / 2.0)
