## CharacterMotor -- owns movement input, MoveContainer, and MovementState.
##
## This keeps movement in the character/player stack. Animation observes the
## published MovementState rather than owning the MoveContainer.
class_name CharacterMotor
extends Node

const _DefaultMovementConfig := preload("res://src/core/character/controller/movement_presets/default_movement_config.tres")
const _MoveContainer := preload("res://src/core/character/controller/move_container.gd")
const _PlayerInputGatherer := preload("res://src/core/character/controller/player_input_gatherer.gd")

@export var movement_config: CharacterMovementConfig = _DefaultMovementConfig

var player: CharacterBody3D = null
var character_root: Node3D = null
var skeleton: Skeleton3D = null
var input_gatherer: PlayerInputGatherer = null
var move_container: MoveContainer = null
var movement_state: MovementState = MovementState.new()


func setup(p_player: CharacterBody3D, p_character_root: Node3D = null,
		p_config: CharacterMovementConfig = null, p_camera_pivot: Node3D = null,
		p_skeleton: Skeleton3D = null) -> void:
	player = p_player
	character_root = p_character_root
	skeleton = p_skeleton
	set_movement_config(p_config)
	_ensure_input_gatherer(p_camera_pivot)
	_ensure_move_container()
	_configure_move_container()


func process(delta: float, is_in_water: bool = false,
		water_surface_y: float = -INF) -> MovementState:
	if not input_gatherer or not move_container:
		return movement_state

	var input := input_gatherer.gather_input(is_in_water, water_surface_y)
	move_container.process(input, delta)
	movement_state = move_container.get_movement_state()
	return movement_state


func set_movement_config(config: CharacterMovementConfig) -> void:
	movement_config = config if config else _DefaultMovementConfig
	if move_container:
		move_container.set_movement_config(movement_config)


func set_camera_pivot(camera_pivot: Node3D) -> void:
	_ensure_input_gatherer(camera_pivot)
	input_gatherer.camera_pivot = camera_pivot


func get_movement_state() -> MovementState:
	return movement_state


func get_move_container() -> MoveContainer:
	return move_container


func _ensure_input_gatherer(camera_pivot: Node3D) -> void:
	if not input_gatherer:
		input_gatherer = _PlayerInputGatherer.new() as PlayerInputGatherer
		input_gatherer.name = "InputGatherer"
		add_child(input_gatherer)
	input_gatherer.camera_pivot = camera_pivot


func _ensure_move_container() -> void:
	if move_container:
		return
	move_container = _MoveContainer.new() as MoveContainer
	move_container.name = "MoveContainer"
	add_child(move_container)
	_add_default_moves()


func _configure_move_container() -> void:
	if not move_container:
		return
	move_container.set_movement_config(movement_config)
	move_container.player = player
	move_container.character_root = character_root
	move_container.animator = null
	move_container.skeleton = skeleton
	move_container.accept_moves()
	movement_state = move_container.get_movement_state()


func _add_default_moves() -> void:
	if not move_container:
		return
	var IdleMoveClass := preload("res://src/core/character/controller/moves/idle_move.gd")
	var WalkMoveClass := preload("res://src/core/character/controller/moves/walk_move.gd")
	var RunMoveClass := preload("res://src/core/character/controller/moves/run_move.gd")
	var SprintMoveClass := preload("res://src/core/character/controller/moves/sprint_move.gd")
	var JumpMoveClass := preload("res://src/core/character/controller/moves/jump_move.gd")
	var MidairMoveClass := preload("res://src/core/character/controller/moves/midair_move.gd")
	var CrouchMoveClass := preload("res://src/core/character/controller/moves/crouch_move.gd")
	var SwimIdleMoveClass := preload("res://src/core/character/controller/moves/swim_idle_move.gd")
	var SwimMoveClass := preload("res://src/core/character/controller/moves/swim_move.gd")

	var idle := IdleMoveClass.new()
	idle.name = "IdleMove"
	move_container.add_child(idle)

	var walk := WalkMoveClass.new()
	walk.name = "WalkMove"
	move_container.add_child(walk)

	var run := RunMoveClass.new()
	run.name = "RunMove"
	move_container.add_child(run)

	var sprint := SprintMoveClass.new()
	sprint.name = "SprintMove"
	move_container.add_child(sprint)

	var jump := JumpMoveClass.new()
	jump.name = "JumpMove"
	move_container.add_child(jump)

	var midair := MidairMoveClass.new()
	midair.name = "MidairMove"
	move_container.add_child(midair)

	var crouch := CrouchMoveClass.new()
	crouch.name = "CrouchMove"
	move_container.add_child(crouch)

	var swim_idle := SwimIdleMoveClass.new()
	swim_idle.name = "SwimIdleMove"
	move_container.add_child(swim_idle)

	var swim := SwimMoveClass.new()
	swim.name = "SwimMove"
	move_container.add_child(swim)
