# MIT License.
# Made by Dylearn

# Crater left by an explosion. Destroys grass via a GrassEffector2D child
# set to BLEND_MODE_SUB.  After a hold period the effector fades out (grass
# regrows), then the crater visual fades and the node is freed.

extends Node2D

@export var hold_time: float = 5.0
@export var regrow_time: float = 5.0
@export var sprite_fade_time: float = 2.0

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _effector: Node2D = $GrassEffector2D


func _ready() -> void:
	rotation = randf() * TAU
	await get_tree().create_timer(hold_time).timeout
	var tween := create_tween()
	tween.tween_property(_effector, "modulate:a", 0.0, regrow_time)
	tween.tween_property(_sprite, "modulate:a", 0.0, sprite_fade_time)
	tween.tween_callback(queue_free)
