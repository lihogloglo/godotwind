@tool
extends EditorPlugin

var dock : CloudsEditorController

func _handles(object: Object) -> bool:
	return object is SunshineCloudsDriverGD

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if dock.currentDrawMode == CloudsEditorController.DRAWINGMODE.none:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	
	if (Input.is_key_pressed(KEY_ESCAPE)):
		dock.DrawModeCancel()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	
	if (Input.is_key_pressed(KEY_CTRL)):
		dock.SetDrawInvert(true)
	else:
		dock.SetDrawInvert(false)
	
	if event is InputEventMouse:
		dock.IterateCursorLocation(viewport_camera, event)
	
	if (event is InputEventMouseButton):
		if (event.button_index == MOUSE_BUTTON_LEFT):
			if event.is_pressed():
				dock.BeginCursorDraw()
				Input.mouse_mode = Input.MOUSE_MODE_CONFINED_HIDDEN
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			elif dock.drawingCurrently:
				dock.EndCursorDraw()
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif !Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			if (event.button_index == MOUSE_BUTTON_WHEEL_UP):
				dock.ScaleDrawingCircleUp()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			elif (event.button_index == MOUSE_BUTTON_WHEEL_DOWN):
				dock.ScaleDrawingCircleDown()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
	
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func _enter_tree() -> void:
	dock = preload("res://addons/SunshineClouds2/Dock/CloudsEditorDock.tscn").instantiate() as CloudsEditorController
	add_control_to_dock(DOCK_SLOT_LEFT_UR, dock)
	
	scene_changed.connect(dock.SceneChanged)
	dock.call_deferred(&"InitialSceneLoad")
	set_input_event_forwarding_always_enabled()


func _exit_tree() -> void:
	scene_changed.disconnect(dock.SceneChanged)
	
	remove_control_from_docks(dock)
	dock.free()
