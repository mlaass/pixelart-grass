# MIT License.
# Made by Jomoho Games, based on original work by Dylearn

# Bomb that sits for a fuse period then explodes, spawning a Crater scene,
# a one-shot particle burst, and a brief camera shake.

extends Node2D

const CRATER_SCENE := preload("res://example/scenes/Crater.tscn")
@onready var bomb_sprite = %BombAnim
@export var fuse_time: float = 3.0

var _elapsed: float = 0.0


func _ready() -> void:
  await get_tree().create_timer(fuse_time).timeout
  set_process(false)
  _explode()


func _process(delta: float) -> void:
  # Accelerating pulse: frequency increases as elapsed approaches fuse_time
  _elapsed += delta
  var t: float = clampf(_elapsed / fuse_time, 0.0, 1.0)
  var freq: float = lerpf(3.0, 20.0, t * t)
  var pulse: float = 1.0 + 0.3 * absf(sin(_elapsed * freq))
  bomb_sprite.scale = Vector2(pulse, pulse)


func _explode() -> void:
  # Spawn crater at bomb position
  var crater := CRATER_SCENE.instantiate()
  crater.position = global_position
  get_parent().add_child(crater)

  # One-shot particle burst
  var particles := CPUParticles2D.new()
  particles.position = global_position
  particles.emitting = true
  particles.one_shot = true
  particles.explosiveness = 1.0
  particles.amount = 16
  particles.lifetime = 0.4
  particles.direction = Vector2(0, -1)
  particles.spread = 180.0
  particles.initial_velocity_min = 40.0
  particles.initial_velocity_max = 80.0
  particles.gravity = Vector2(0, 200)
  particles.scale_amount_min = 1.0
  particles.scale_amount_max = 2.0
  particles.color = Color(0.45, 0.3, 0.15)
  get_parent().add_child(particles)
  get_tree().create_timer(particles.lifetime + 0.1).timeout.connect(particles.queue_free)

  # Camera shake
  var cam := get_viewport().get_camera_2d()
  if cam:
    var tween := create_tween().set_trans(Tween.TRANS_SINE)
    for i in 6:
      var shake := Vector2(randf_range(-4.0, 4.0), randf_range(-4.0, 4.0))
      tween.tween_property(cam, "offset", shake, 0.05)
    tween.tween_property(cam, "offset", Vector2.ZERO, 0.05)

  queue_free()
