extends Node


func _ready() -> void:
	var runner := GdUnitTestCIRunner.new()
	runner._debug_cmd_args = [
		"GdUnitCmdTool.gd",
		"--add",
		"res://tests/unit/test_water_body_registry.gd",
		"--continue",
	]
	add_child(runner)
