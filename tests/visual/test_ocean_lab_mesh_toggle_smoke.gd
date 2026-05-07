extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for Ocean Lab mesh-mode rebuilds.
## Inherits the interactive lab and flips CLIPMAP -> PROJECTED -> CLIPMAP
## without screenshots or camera scripting.

func _ready() -> void:
	super._ready()
	print("[Ocean Lab Smoke] Ready")
	_toggle_mesh("projected")
	_toggle_mesh("clipmap")
	print("[Ocean Lab Smoke] Mesh toggle round trip completed")
	get_tree().quit(0)


func _toggle_mesh(label: String) -> void:
	print("[Ocean Lab Smoke] toggling mesh mode to %s" % label)
	_toggle_mesh_mode()
