# MIT License.
# Made by Jomoho Games

@tool
extends AnimatedSprite2D

const BOMB_SCENE := preload("res://example/scenes/Bomb.tscn")

@export var move_speed: float = 200.0


func _process(delta: float) -> void:
	if Engine.is_editor_hint(): return
	var input := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down"))
	position += input * move_speed * delta

	if input.length_squared() > 0.0:
		play("walk")
		if input.x != 0.0:
			flip_h = input.x < 0.0
	else:
		play("idle")


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint(): return
	if event.is_action_pressed("ui_accept"):
		var bomb := BOMB_SCENE.instantiate()
		bomb.position = global_position
		get_parent().add_child(bomb)
