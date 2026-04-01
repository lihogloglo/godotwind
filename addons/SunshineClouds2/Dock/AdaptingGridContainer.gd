@tool
extends GridContainer

@export var TargetColumnCount : int = 1
@export var MinimumColumnSize : float = 100.0

func _enter_tree() -> void:
	if (!self.resized.is_connected(OnSizeChange.bind())):
		self.resized.connect(OnSizeChange.bind())

func OnSizeChange():
	if (TargetColumnCount <= 0):
		TargetColumnCount = 0
	
	var width = size.x
	var newColumnCount : int = clamp(floor(width / MinimumColumnSize), 1, TargetColumnCount)
	columns = newColumnCount
