## LakeDatabaseLoader - Load and save Morrowind lake definitions from JSON
## Manages collections of PolygonWaterVolume instances
class_name LakeDatabaseLoader
extends Node

## Load lakes from JSON file and instantiate them in the scene
static func load_lakes_from_json(json_path: String, parent: Node) -> Array[PolygonWaterVolume]:
	var lakes: Array[PolygonWaterVolume] = []

	if not FileAccess.file_exists(json_path):
		push_warning("[LakeDatabaseLoader] Lake database not found: %s" % json_path)
		return lakes

	var file := FileAccess.open(json_path, FileAccess.READ)
	if not file:
		push_error("[LakeDatabaseLoader] Failed to open lake database: %s" % json_path)
		return lakes

	var json_text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var error := json.parse(json_text)
	if error != OK:
		push_error("[LakeDatabaseLoader] Failed to parse JSON: %s (line %d)" % [
			json.get_error_message(), json.get_error_line()])
		return lakes

	var data = json.data
	if not data is Dictionary:
		push_error("[LakeDatabaseLoader] Invalid JSON format - expected Dictionary")
		return lakes

	# Load lakes from different regions
	var total_loaded := 0
	for region_key in data.keys():
		var region_lakes = data[region_key]
		if not region_lakes is Array:
			continue

		for lake_data in region_lakes:
			if not lake_data is Dictionary:
				continue

			var lake := PolygonWaterVolume.new()
			lake.import_from_json(lake_data)
			parent.add_child(lake)
			lakes.append(lake)
			total_loaded += 1

	print("[LakeDatabaseLoader] Loaded %d lakes from %s" % [total_loaded, json_path])
	return lakes


## Save current lakes to JSON file
static func save_lakes_to_json(json_path: String, lakes: Array[PolygonWaterVolume], region_name: String = "default_region") -> bool:
	var lake_data: Array = []

	for lake in lakes:
		if lake:
			lake_data.append(lake.export_to_json())

	var data := {
		region_name: lake_data
	}

	var json_text := JSON.stringify(data, "\t")
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if not file:
		push_error("[LakeDatabaseLoader] Failed to open file for writing: %s" % json_path)
		return false

	file.store_string(json_text)
	file.close()

	print("[LakeDatabaseLoader] Saved %d lakes to %s" % [lake_data.size(), json_path])
	return true


## Create example Morrowind lakes database (template)
static func create_example_database(json_path: String) -> bool:
	var example_data := {
		"vvardenfell_lakes": [
			{
				"name": "Lake Amaya",
				"region": "Ascadian Isles",
				"water_type": "LAKE",
				"position": [12500.0, -1000.0, 8300.0],
				"water_surface_height": -1000.0,
				"depth": 20.0,
				"polygon": [
					[12400, 8200],
					[12700, 8150],
					[12900, 8250],
					[12950, 8400],
					[12800, 8550],
					[12500, 8600],
					[12300, 8500],
					[12250, 8350]
				],
				"water_color": [0.02, 0.12, 0.18, 1.0],
				"clarity": 0.3,
				"enable_waves": true,
				"wave_scale": 0.2,
				"flow_direction": null,
				"flow_speed": null
			},
			{
				"name": "Odai River",
				"region": "Ascadian Isles",
				"water_type": "RIVER",
				"position": [11000.0, -1000.0, 9000.0],
				"water_surface_height": -1000.0,
				"depth": 8.0,
				"polygon": [
					[10900, 8900],
					[11000, 8880],
					[11100, 8920],
					[11150, 9050],
					[11100, 9150],
					[11000, 9180],
					[10920, 9100],
					[10900, 9000]
				],
				"water_color": [0.02, 0.14, 0.2, 1.0],
				"clarity": 0.5,
				"enable_waves": true,
				"wave_scale": 0.15,
				"flow_direction": [0.3, 1.0],
				"flow_speed": 2.5
			}
		],
		"bitter_coast_lakes": [
			{
				"name": "Unnamed Pond",
				"region": "Bitter Coast",
				"water_type": "LAKE",
				"position": [8500.0, -1000.0, 5200.0],
				"water_surface_height": -1000.0,
				"depth": 5.0,
				"polygon": [
					[8450, 5150],
					[8550, 5140],
					[8580, 5220],
					[8540, 5280],
					[8460, 5260]
				],
				"water_color": [0.015, 0.1, 0.15, 1.0],
				"clarity": 0.25,
				"enable_waves": true,
				"wave_scale": 0.1,
				"flow_direction": null,
				"flow_speed": null
			}
		]
	}

	var json_text := JSON.stringify(example_data, "\t")
	var file := FileAccess.open(json_path, FileAccess.WRITE)
	if not file:
		push_error("[LakeDatabaseLoader] Failed to create example database: %s" % json_path)
		return false

	file.store_string(json_text)
	file.close()

	print("[LakeDatabaseLoader] Created example database: %s" % json_path)
	return true


## Get all PolygonWaterVolume nodes in a scene
static func find_all_lakes_in_scene(root: Node) -> Array[PolygonWaterVolume]:
	var lakes: Array[PolygonWaterVolume] = []
	_find_lakes_recursive(root, lakes)
	return lakes


static func _find_lakes_recursive(node: Node, lakes: Array[PolygonWaterVolume]) -> void:
	if node is PolygonWaterVolume:
		lakes.append(node)

	for child in node.get_children():
		_find_lakes_recursive(child, lakes)


## Calculate total water surface area in scene
static func calculate_total_water_area(lakes: Array[PolygonWaterVolume]) -> float:
	var total := 0.0
	for lake in lakes:
		if lake:
			total += lake.get_polygon_area()
	return total


## Export statistics about lake database
static func get_database_stats(lakes: Array[PolygonWaterVolume]) -> Dictionary:
	var stats := {
		"total_lakes": lakes.size(),
		"total_area": 0.0,
		"by_type": {},
		"average_depth": 0.0,
		"total_depth": 0.0
	}

	for lake in lakes:
		if not lake:
			continue

		stats["total_area"] += lake.get_polygon_area()
		stats["total_depth"] += lake.size.y

		var type_name := WaterVolume.WaterType.keys()[lake.water_type]
		if not type_name in stats["by_type"]:
			stats["by_type"][type_name] = 0
		stats["by_type"][type_name] += 1

	if lakes.size() > 0:
		stats["average_depth"] = stats["total_depth"] / float(lakes.size())

	return stats
