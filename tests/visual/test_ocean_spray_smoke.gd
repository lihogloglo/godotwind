extends "res://tests/visual/test_ocean_lab.gd"

## Crash smoke for OceanSpray.
## Inherits the interactive lab, switches to storm weather so the spray layer
## emits, waits a few frames for the GPU particle path to run, then exits.

func _ready() -> void:
	super._ready()
	if OceanManager == null:
		push_error("[Ocean Spray Smoke] OceanManager missing")
		get_tree().quit(1)
		return

	if OceanManager.has_method("set_sea_spray_enabled"):
		OceanManager.set_sea_spray_enabled(true)
	if OceanManager.has_method("set_sea_spray_quality"):
		OceanManager.set_sea_spray_quality(3)
	_apply_weather_preset(3)

	for _i in range(8):
		await get_tree().process_frame

	var spray: OceanSpray = OceanManager.get_ocean_spray() if OceanManager.has_method("get_ocean_spray") else null
	var spray_energy: float = OceanManager.get_sea_spray_energy() if OceanManager.has_method("get_sea_spray_energy") else 0.0
	if spray == null or spray_energy <= 0.01 or spray.get_particle_count() <= 0:
		push_error("[Ocean Spray Smoke] Spray path did not activate: spray=%s energy=%.3f particles=%d" % [
			str(spray),
			spray_energy,
			spray.get_particle_count() if spray else 0
		])
		get_tree().quit(1)
		return

	print("[Ocean Spray Smoke] spray active energy=%.3f particles=%d" % [
		spray_energy,
		spray.get_particle_count()
	])

	OceanManager.set_sea_spray_enabled(false)
	await get_tree().process_frame
	var disabled_status: Dictionary = OceanManager.get_sea_spray_status()
	if bool(disabled_status.get("emitting", true)):
		push_error("[Ocean Spray Smoke] Spray still emitting after disable")
		get_tree().quit(1)
		return

	OceanManager.set_sea_spray_enabled(true)
	await get_tree().process_frame
	var reenabled_status: Dictionary = OceanManager.get_sea_spray_status()
	if not bool(reenabled_status.get("emitting", false)):
		push_error("[Ocean Spray Smoke] Spray did not resume after re-enable")
		get_tree().quit(1)
		return

	print("[Ocean Spray Smoke] toggle off/on passed")
	get_tree().quit(0)
