## Character Controller Test — Playable test scene for the Move-as-Node system
##
## Controls:
##   WASD = move, Shift = sprint, Space = jump, C/Ctrl = crouch
##   Mouse = look, Tab = toggle 1st/3rd person, ESC = release mouse
##   1-5 = spawn preset NPCs
##   F1 = toggle debug HUD
##   F2 = dump KF vs actual bone comparison to console
@warning_ignore("untyped_declaration", "unsafe_method_access")
extends Node3D

const LoadingScreenScript := preload("res://src/core/ui/loading_screen.gd")
const CharacterFactoryV2Script := preload("res://src/core/animation/character_factory_v2.gd")
const PlayerControllerScript := preload("res://src/core/player/player_controller.gd")
const MorrowindMovementConfig := preload("res://src/core/character/controller/movement_presets/morrowind_movement_config.tres")
const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")

# Preset Morrowind NPCs
const PRESET_NPCS := [
	"fargoth",            # 1 - Male Wood Elf
	"caius cosades",      # 2 - Male Imperial
	"ranis athrys",       # 3 - Female Dark Elf
	"arrille",            # 4 - Male High Elf
	"sugar-lips habasi",  # 5 - Female Khajiit (beast)
]

var _player_controller: CharacterBody3D
var _factory: RefCounted
var _debug_hud: RichTextLabel
var _debug_visible: bool = true
var _is_loading: bool = false


func _ready() -> void:
	_create_environment()
	_create_terrain()
	_create_water_pool()
	_create_points_of_interest()
	_create_pushable_objects()
	_create_debug_hud()

	# Ocean disabled — buggy in test scene, to be fixed separately
	#_setup_ocean()

	# Factory for creating MW NPCs
	_factory = CharacterFactoryV2Script.new()
	_factory.enable_ik = true
	_factory.enable_wander = false
	_factory.debug_characters = true
	_factory.debug_animations = true
	# Clear cached bone remaps to ensure clean state (avoids stale empty remaps)
	CharacterFactoryV2Script.clear_all_caches()

	# Load game data with loading screen
	var loading := LoadingScreenScript.new()
	add_child(loading)
	var success := await loading.load_game_data()
	loading.queue_free()
	if not success:
		return

	# Spawn default NPC
	_spawn_npc(PRESET_NPCS[0])


func _input(event: InputEvent) -> void:
	# Number keys spawn preset NPCs
	if event is InputEventKey and event.pressed and not event.echo:
		var key_idx: int = event.keycode - KEY_1
		if key_idx >= 0 and key_idx < PRESET_NPCS.size():
			_spawn_npc(PRESET_NPCS[key_idx])
		elif event.keycode == KEY_F1:
			_debug_visible = not _debug_visible
			if _debug_hud:
				_debug_hud.visible = _debug_visible
		elif event.keycode == KEY_F2:
			_dump_kf_comparison()


func _physics_process(_delta: float) -> void:
	if _debug_visible and _debug_hud and _player_controller:
		_update_debug_hud()


# =============================================================================
# NPC SPAWNING
# =============================================================================

func _spawn_npc(npc_id: String) -> void:
	if _is_loading:
		return
	_is_loading = true

	# Remove existing player
	if _player_controller:
		_player_controller.disable()
		_player_controller.queue_free()
		_player_controller = null
		await get_tree().process_frame

	# Look up NPC record (on-demand creation from C# cache)
	var out_type: Array = [""]
	var record = ESMManager.get_any_record(npc_id, out_type)
	if not record or out_type[0] != "npc":
		Log.warn("testing", "NPC not found: %s (type: %s)" % [npc_id, str(out_type[0])])
		_is_loading = false
		return
	var npc_record: NPCRecord = ESMManager.get_npc(npc_id)

	Log.info("testing", "Spawning NPC: %s (%s)" % [npc_id, npc_record.race_id])

	# Get race info
	var race = ESMManager.get_race(npc_record.race_id)
	if not race:
		Log.warn("testing", "Race not found: %s" % npc_record.race_id)
		_is_loading = false
		return

	# Assemble body parts (skeleton + meshes)
	var MorrowindNPCAssembler := preload("res://src/core/character/morrowind/morrowind_npc_assembler.gd")
	var character_root: Node3D = MorrowindNPCAssembler.assemble(npc_record, race)
	if not character_root:
		Log.error("testing", "Failed to assemble NPC: %s" % npc_id)
		_is_loading = false
		return

	# Find skeleton
	var SkeletonUtils := preload("res://src/core/animation/skeleton_utils.gd")
	var skeleton: Skeleton3D = _find_skeleton(character_root)
	var is_female: bool = npc_record.is_female()
	var is_beast: bool = race.is_beast() if race else false

	if skeleton:
		# Build bone remap BEFORE renaming — maps Bip01 names → profile names
		_factory._ensure_bone_remap(skeleton, is_beast)

		# NOW rename skeleton bones (Bip01 Head → Head, etc.)
		var rename_map := SkeletonUtils.rename_bones_to_profile(skeleton)
		if not rename_map.is_empty():
			_update_bone_attachment_names(skeleton, rename_map)

	# Create PlayerController FIRST and add to scene tree
	_player_controller = PlayerControllerScript.new()
	_player_controller.name = "Player_%s" % npc_id
	_player_controller.movement_config = MorrowindMovementConfig
	add_child(_player_controller)
	_player_controller.global_position = Vector3(-5, 2, 5)

	# Add character root to PlayerController
	_player_controller.add_child(character_root)

	# Load KF animations (uses cached remap to convert Bip01 track names → profile names)
	_factory._load_character_animations(character_root, skeleton, is_female, is_beast)

	# --- DIAGNOSTIC: verify tracks match skeleton bones ---
	_diagnose_animation_binding(character_root, skeleton)

	# Wire animation system on OUR PlayerController (AnimationManager, IK).
	# PlayerController owns movement through CharacterMotor.
	_factory.setup_character(_player_controller, is_female, is_beast,
		npc_record.race_id, npc_record.record_id)

	# Create input gatherer and wire camera
	_player_controller._setup_input_gatherer()

	# Enable player control
	_player_controller.enable()

	# Add forward-direction indicator arrow
	_add_front_indicator(character_root)

	Log.info("testing", "Player controller ready for %s" % npc_id)

	# Deep pipeline diagnostic — runs once after spawn to identify animation issues
	await get_tree().process_frame
	_dump_pipeline_diagnostic()
	_is_loading = false


# =============================================================================
# FRONT INDICATOR — debug arrow showing character facing direction
# =============================================================================

func _add_front_indicator(char_root: Node3D) -> void:
	# Remove old indicator if respawning
	var old := char_root.get_node_or_null("FrontIndicator")
	if old:
		old.queue_free()

	var indicator := Node3D.new()
	indicator.name = "FrontIndicator"

	# Arrow shaft — thin cylinder pointing forward (-Z in Godot)
	var shaft := MeshInstance3D.new()
	shaft.name = "Shaft"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.02
	cyl.bottom_radius = 0.02
	cyl.height = 0.6
	shaft.mesh = cyl
	# Cylinder default is Y-up; rotate to point forward (-Z)
	shaft.rotation.x = deg_to_rad(90)
	shaft.position.z = -0.3  # Center the shaft ahead of origin
	indicator.add_child(shaft)

	# Arrow head — cone at the tip
	var head := MeshInstance3D.new()
	head.name = "Head"
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.06
	cone.height = 0.15
	head.mesh = cone
	head.rotation.x = deg_to_rad(90)
	head.position.z = -0.675  # Just past the shaft end
	indicator.add_child(head)

	# Bright red material for visibility
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.1, 0.1)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	shaft.material_override = mat
	head.material_override = mat

	# Position at waist height so it's visible from above
	indicator.position.y = 1.0

	char_root.add_child(indicator)


# =============================================================================
# ENVIRONMENT
# =============================================================================

func _create_environment() -> void:
	# DirectionalLight
	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.rotation = Vector3(deg_to_rad(-45), deg_to_rad(30), 0)
	light.light_energy = 1.0
	light.shadow_enabled = true
	add_child(light)

	# WorldEnvironment
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.5
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)


func _setup_ocean() -> void:
	# Initialize ocean — sea level well below platform so FFT waves don't reach ground
	# Platform ground is at Y=0. FFT waves have ~1-2m amplitude around sea_level.
	# Setting sea_level=-3 gives 1-2m clearance even at wave peaks.
	OceanManager.force_initialize()
	OceanManager.set_sea_level(-3.0)
	OceanManager.set_enabled(true)


func _create_terrain() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.5, 0.2)

	# Ground with hole for pool — pool is 20x20 centered at (8, 0, -8)
	# Pool spans X: [-2, 18], Z: [-18, 2]
	# Split ground into 4 sections around the pool opening
	var sections := [
		# [name, center_x, center_z, size_x, size_z]
		["Ground_Left", -26.0, 0.0, 48.0, 100.0],   # X: [-50, -2]
		["Ground_Right", 34.0, 0.0, 32.0, 100.0],    # X: [18, 50]
		["Ground_Back", 8.0, 26.0, 20.0, 48.0],      # Z: [2, 50]
		["Ground_Front", 8.0, -34.0, 20.0, 32.0],    # Z: [-50, -18]
	]
	for s in sections:
		var ground := MeshInstance3D.new()
		ground.name = s[0]
		var plane := PlaneMesh.new()
		plane.size = Vector2(s[3], s[4])
		ground.mesh = plane
		ground.material_override = mat
		ground.position = Vector3(s[1], 0, s[2])
		add_child(ground)

	# Collision — 4 matching static bodies
	for s in sections:
		var body := StaticBody3D.new()
		body.name = s[0] + "Body"
		var col := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(s[3], 0.1, s[4])
		col.shape = shape
		col.position.y = -0.05
		body.add_child(col)
		body.position = Vector3(s[1], 0, s[2])
		add_child(body)

	# Slope ramp
	var ramp := MeshInstance3D.new()
	ramp.name = "Ramp"
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(4, 0.2, 8)
	ramp.mesh = box_mesh
	ramp.position = Vector3(10, 1.5, 0)
	ramp.rotation.x = deg_to_rad(-20)
	ramp.material_override = mat.duplicate()
	ramp.material_override.albedo_color = Color(0.5, 0.4, 0.3)
	add_child(ramp)

	var ramp_body := StaticBody3D.new()
	ramp_body.name = "RampBody"
	var ramp_col := CollisionShape3D.new()
	var ramp_shape := BoxShape3D.new()
	ramp_shape.size = Vector3(4, 0.2, 8)
	ramp_col.shape = ramp_shape
	ramp_body.add_child(ramp_col)
	ramp_body.position = Vector3(10, 1.5, 0)
	ramp_body.rotation.x = deg_to_rad(-20)
	add_child(ramp_body)

	# Tall wall for climbing test (Phase 5)
	var wall := MeshInstance3D.new()
	wall.name = "ClimbWall"
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(6, 8, 0.5)
	wall.mesh = wall_mesh
	wall.position = Vector3(-10, 4, 0)
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.6, 0.55, 0.5)
	wall.material_override = wall_mat
	add_child(wall)

	var wall_body := StaticBody3D.new()
	wall_body.name = "WallBody"
	var wall_col := CollisionShape3D.new()
	var wall_shape := BoxShape3D.new()
	wall_shape.size = Vector3(6, 8, 0.5)
	wall_col.shape = wall_shape
	wall_body.add_child(wall_col)
	wall_body.position = Vector3(-10, 4, 0)
	add_child(wall_body)

	# IK test obstacles — small boxes at varying heights for foot IK adaptation
	var ik_mat := StandardMaterial3D.new()
	ik_mat.albedo_color = Color(0.55, 0.45, 0.35)
	var ik_boxes := [
		# [name, position, size] — scattered near spawn area
		["IKBox_Low1", Vector3(-3, 0.05, 3), Vector3(1.0, 0.1, 1.0)],     # 10cm step
		["IKBox_Low2", Vector3(-1, 0.08, 4), Vector3(0.8, 0.16, 0.8)],    # 16cm step
		["IKBox_Med1", Vector3(1, 0.12, 2), Vector3(0.7, 0.24, 0.7)],     # 24cm step
		["IKBox_Med2", Vector3(2, 0.1, 5), Vector3(1.2, 0.2, 0.6)],       # 20cm plank
		["IKBox_High", Vector3(0, 0.15, 6), Vector3(0.6, 0.3, 0.6)],      # 30cm block
		["IKBox_Flat", Vector3(-2, 0.025, 6), Vector3(2.0, 0.05, 1.5)],   # 5cm slab
		["IKBox_Step1", Vector3(4, 0.1, 3), Vector3(1.5, 0.2, 0.5)],      # stair step 1
		["IKBox_Step2", Vector3(4, 0.2, 2.5), Vector3(1.5, 0.4, 0.5)],    # stair step 2
		["IKBox_Step3", Vector3(4, 0.3, 2.0), Vector3(1.5, 0.6, 0.5)],    # stair step 3
	]
	for b in ik_boxes:
		var bx_mesh := MeshInstance3D.new()
		bx_mesh.name = b[0]
		var bx := BoxMesh.new()
		bx.size = b[2]
		bx_mesh.mesh = bx
		bx_mesh.position = b[1]
		bx_mesh.material_override = ik_mat
		add_child(bx_mesh)

		var bx_body := StaticBody3D.new()
		bx_body.name = b[0] + "Body"
		var bx_col := CollisionShape3D.new()
		var bx_shape := BoxShape3D.new()
		bx_shape.size = b[2]
		bx_col.shape = bx_shape
		bx_body.add_child(bx_col)
		bx_body.position = b[1]
		add_child(bx_body)


func _create_water_pool() -> void:
	# Pool: 20x20 hole in the ground, water surface at Y=-1.0, floor at Y=-4.0
	var pool_x := 8.0
	var pool_z := -8.0
	var pool_half := 10.0  # half-size (20/2)
	var surface_y := -1.0
	var floor_y := -4.0
	var wall_depth: float = -floor_y  # 4m from ground to floor

	# Water surface — semi-transparent blue plane
	var pool := MeshInstance3D.new()
	pool.name = "WaterPool"
	var pool_mesh := PlaneMesh.new()
	pool_mesh.size = Vector2(pool_half * 2, pool_half * 2)
	pool.mesh = pool_mesh
	pool.position = Vector3(pool_x, surface_y, pool_z)
	var water_mat := StandardMaterial3D.new()
	water_mat.albedo_color = Color(0.1, 0.3, 0.6, 0.5)
	water_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pool.material_override = water_mat
	add_child(pool)

	# Basin walls — 4 vertical planes lining the pool edges
	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.25, 0.35, 0.3)
	# [name, pos, size] — walls are thin boxes
	var walls := [
		["PoolWall_N", Vector3(pool_x, -wall_depth / 2.0, pool_z + pool_half), Vector3(pool_half * 2, wall_depth, 0.1)],
		["PoolWall_S", Vector3(pool_x, -wall_depth / 2.0, pool_z - pool_half), Vector3(pool_half * 2, wall_depth, 0.1)],
		["PoolWall_E", Vector3(pool_x + pool_half, -wall_depth / 2.0, pool_z), Vector3(0.1, wall_depth, pool_half * 2)],
		["PoolWall_W", Vector3(pool_x - pool_half, -wall_depth / 2.0, pool_z), Vector3(0.1, wall_depth, pool_half * 2)],
	]
	for w in walls:
		var wm := MeshInstance3D.new()
		wm.name = w[0]
		var bm := BoxMesh.new()
		bm.size = w[2]
		wm.mesh = bm
		wm.position = w[1]
		wm.material_override = wall_mat
		add_child(wm)

		# Wall collision
		var wb := StaticBody3D.new()
		wb.name = w[0] + "Body"
		var wc := CollisionShape3D.new()
		var ws := BoxShape3D.new()
		ws.size = w[2]
		wc.shape = ws
		wb.add_child(wc)
		wb.position = w[1]
		add_child(wb)

	# Pool floor
	var pool_ground := MeshInstance3D.new()
	pool_ground.name = "PoolGround"
	var pg_mesh := PlaneMesh.new()
	pg_mesh.size = Vector2(pool_half * 2, pool_half * 2)
	pool_ground.mesh = pg_mesh
	pool_ground.position = Vector3(pool_x, floor_y, pool_z)
	var pg_mat := StandardMaterial3D.new()
	pg_mat.albedo_color = Color(0.2, 0.3, 0.25)
	pool_ground.material_override = pg_mat
	add_child(pool_ground)

	var pool_body := StaticBody3D.new()
	pool_body.name = "PoolGroundBody"
	var pool_col := CollisionShape3D.new()
	var pool_shape := BoxShape3D.new()
	pool_shape.size = Vector3(pool_half * 2, 0.1, pool_half * 2)
	pool_col.shape = pool_shape
	pool_body.add_child(pool_col)
	pool_body.position = Vector3(pool_x, floor_y - 0.05, pool_z)
	add_child(pool_body)

	# Water volume Area3D — triggers swimming when player enters
	var water_area := Area3D.new()
	water_area.name = "WaterVolume"
	water_area.collision_layer = 0
	water_area.collision_mask = GameplayPhysicsLayersScript.PLAYER
	var area_col := CollisionShape3D.new()
	var area_shape := BoxShape3D.new()
	var detector_margin_above_surface := 4.0
	var vol_height: float = surface_y - floor_y + detector_margin_above_surface
	area_shape.size = Vector3(pool_half * 2, vol_height, pool_half * 2)
	area_col.shape = area_shape
	water_area.add_child(area_col)
	water_area.position = Vector3(
		pool_x,
		(floor_y + surface_y + detector_margin_above_surface) / 2.0,
		pool_z
	)
	add_child(water_area)

	# Connect Area3D signals to player controller
	water_area.body_entered.connect(func(body: Node3D) -> void:
		if body is CharacterBody3D and body.has_method("enter_water_volume"):
			body.enter_water_volume(surface_y)
	)
	water_area.body_exited.connect(func(body: Node3D) -> void:
		if body is CharacterBody3D and body.has_method("exit_water_volume"):
			body.exit_water_volume()
	)


# =============================================================================
# POINTS OF INTEREST — objects the character looks at via look-at IK
# =============================================================================

func _create_points_of_interest() -> void:
	# Signpost near spawn
	_add_poi(Vector3(3, 0, 3), "Signpost", Color(0.6, 0.4, 0.2), "signpost")
	# Lantern on a pole
	_add_poi(Vector3(-4, 0, 5), "Lantern", Color(0.9, 0.7, 0.2), "lantern")
	# Crate near ramp
	_add_poi(Vector3(8, 0, -3), "Crate", Color(0.5, 0.35, 0.2), "crate")
	# Barrel near pool
	_add_poi(Vector3(0, 0, -6), "Barrel", Color(0.4, 0.3, 0.2), "barrel")
	# Torch by the wall
	_add_poi(Vector3(-8, 0, 2), "Torch", Color(0.8, 0.5, 0.1), "torch")
	# Rock formation
	_add_poi(Vector3(6, 0, 8), "Rock", Color(0.45, 0.42, 0.38), "rock")


func _add_poi(pos: Vector3, poi_name: String, color: Color, shape_type: String) -> void:
	var poi := Node3D.new()
	poi.name = "POI_" + poi_name
	poi.position = pos
	poi.add_to_group("poi")

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color

	if shape_type == "signpost":
		# Tall post with a sign
		var post := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.05
		cyl.bottom_radius = 0.05
		cyl.height = 1.8
		post.mesh = cyl
		post.position.y = 0.9
		post.material_override = mat
		poi.add_child(post)
		var sign_board := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.6, 0.3, 0.05)
		sign_board.mesh = box
		sign_board.position = Vector3(0, 1.6, 0)
		sign_board.material_override = mat
		poi.add_child(sign_board)
	elif shape_type == "lantern":
		# Pole with glowing orb on top
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.04
		cyl.bottom_radius = 0.06
		cyl.height = 2.0
		pole.mesh = cyl
		pole.position.y = 1.0
		pole.material_override = mat
		poi.add_child(pole)
		var orb := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.15
		sphere.height = 0.3
		orb.mesh = sphere
		orb.position.y = 2.1
		var glow_mat := StandardMaterial3D.new()
		glow_mat.albedo_color = Color(1.0, 0.9, 0.4)
		glow_mat.emission_enabled = true
		glow_mat.emission = Color(1.0, 0.8, 0.3)
		glow_mat.emission_energy_multiplier = 2.0
		orb.material_override = glow_mat
		poi.add_child(orb)
	elif shape_type == "barrel":
		var barrel := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.3
		cyl.bottom_radius = 0.35
		cyl.height = 1.0
		barrel.mesh = cyl
		barrel.position.y = 0.5
		barrel.material_override = mat
		poi.add_child(barrel)
	elif shape_type == "crate":
		var crate := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.7, 0.7, 0.7)
		crate.mesh = box
		crate.position.y = 0.35
		crate.material_override = mat
		poi.add_child(crate)
	elif shape_type == "torch":
		var pole := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.03
		cyl.bottom_radius = 0.04
		cyl.height = 1.5
		pole.mesh = cyl
		pole.position.y = 0.75
		pole.material_override = mat
		poi.add_child(pole)
		# Flame
		var flame := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.1
		sphere.height = 0.2
		flame.mesh = sphere
		flame.position.y = 1.6
		var flame_mat := StandardMaterial3D.new()
		flame_mat.albedo_color = Color(1.0, 0.4, 0.1)
		flame_mat.emission_enabled = true
		flame_mat.emission = Color(1.0, 0.3, 0.0)
		flame_mat.emission_energy_multiplier = 3.0
		flame.material_override = flame_mat
		poi.add_child(flame)
	else:
		# Default: simple sphere
		var mesh := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.4
		sphere.height = 0.8
		mesh.mesh = sphere
		mesh.position.y = 0.4
		mesh.material_override = mat
		poi.add_child(mesh)

	# Collision so POIs are physical objects
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.4
	shape.height = 1.5
	col.shape = shape
	col.position.y = 0.75
	body.add_child(col)
	poi.add_child(body)

	add_child(poi)


# =============================================================================
# PUSHABLE PHYSICS OBJECTS — RigidBody3D objects the player can push around
# =============================================================================

func _create_pushable_objects() -> void:
	# Sphere — rolls when player walks into it (on Ground_Left, X < -2)
	_add_pushable_sphere(Vector3(-5, 0.6, 3), 0.5, 1.0, Color(0.8, 0.2, 0.2))
	# Smaller sphere
	_add_pushable_sphere(Vector3(-3, 0.45, 5), 0.35, 0.5, Color(0.2, 0.6, 0.8))
	# Heavy sphere near ramp
	_add_pushable_sphere(Vector3(-7, 0.5, 1), 0.4, 5.0, Color(0.5, 0.5, 0.5))


func _add_pushable_sphere(pos: Vector3, radius: float, mass_kg: float, color: Color) -> void:
	var body := RigidBody3D.new()
	body.name = "PushableSphere"
	body.mass = mass_kg
	body.position = pos
	body.collision_layer = 1  # Environment/dynamic prop layer
	body.collision_mask = 1 | 2  # Collide with environment + player

	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = radius
	col.shape = shape
	body.add_child(col)

	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	mesh.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material_override = mat
	body.add_child(mesh)

	add_child(body)


# =============================================================================
# DEBUG HUD
# =============================================================================

func _create_debug_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "DebugCanvas"
	add_child(canvas)

	_debug_hud = RichTextLabel.new()
	_debug_hud.name = "DebugHUD"
	_debug_hud.bbcode_enabled = true
	_debug_hud.fit_content = true
	_debug_hud.scroll_active = false
	_debug_hud.position = Vector2(10, 10)
	_debug_hud.size = Vector2(400, 300)
	_debug_hud.add_theme_font_size_override("normal_font_size", 14)
	_debug_hud.add_theme_color_override("default_color", Color.WHITE)
	canvas.add_child(_debug_hud)

	# Semi-transparent background
	var panel := PanelContainer.new()
	panel.name = "HUDPanel"
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(5, 5)
	panel.size = Vector2(410, 310)
	panel.z_index = -1
	canvas.add_child(panel)


func _update_debug_hud() -> void:
	if not _player_controller or not _debug_hud:
		return

	var anim_sys = _player_controller.animation_system
	var move_name := "N/A"
	var anim_state := "N/A"
	var sm_node := "N/A"
	var tree_active := "N/A"
	var anim_count := 0
	var state_map_info := ""

	if _player_controller.has_method("get_movement_motor"):
		var motor = _player_controller.get_movement_motor()
		if motor and motor.has_method("get_move_container"):
			var mc = motor.get_move_container()
			if mc and mc.has_method("get_current_move_name"):
				move_name = str(mc.get_current_move_name())
	if anim_sys and anim_sys.has_method("get_animation_manager"):
		var am = anim_sys.get_animation_manager()
		if am and am.has_method("get_current_state"):
			anim_state = str(am.get_current_state())
		# Deep AnimationTree diagnostics
		if am:
			var at = am.get("animation_tree")
			if at and at is AnimationTree:
				tree_active = str(at.active)
				var sm_playback = at.get("parameters/locomotion/playback")
				if sm_playback:
					sm_node = str(sm_playback.get_current_node())
			var ap = am.get("animation_player")
			if ap and ap is AnimationPlayer:
				anim_count = ap.get_animation_list().size()
			var smap = am.get("_state_animation_map")
			if smap and smap is Dictionary:
				var entries := PackedStringArray()
				for key in smap:
					entries.append("%s->%s" % [key, smap[key]])
				state_map_info = ", ".join(entries)

	var vel := _player_controller.velocity
	var h_speed := Vector2(vel.x, vel.z).length()
	var pos := _player_controller.global_position

	var text := "[b]Character Controller Test[/b]\n"
	text += "─────────────────────\n"
	text += "[b]Move:[/b] %s\n" % move_name
	text += "[b]Anim State:[/b] %s\n" % anim_state
	text += "[b]SM Node:[/b] %s\n" % sm_node
	text += "[b]Tree Active:[/b] %s | Anims: %d\n" % [tree_active, anim_count]
	text += "[b]Speed:[/b] %.1f m/s (h: %.1f, v: %.1f)\n" % [vel.length(), h_speed, vel.y]
	text += "[b]Position:[/b] %.1f, %.1f, %.1f\n" % [pos.x, pos.y, pos.z]
	text += "[b]On Floor:[/b] %s\n" % str(_player_controller.is_on_floor())
	text += "[b]In Water:[/b] %s\n" % str(_player_controller.in_water)
	text += "[b]Posture:[/b] %s | Swimming: %s\n" % [
		str(_player_controller.current_posture),
		str(_player_controller.is_swimming),
	]
	text += "[b]Camera:[/b] %s\n" % ("1st Person" if _player_controller.camera_mode == 0 else "3rd Person")
	if not state_map_info.is_empty():
		text += "[b]State Map:[/b] %s\n" % state_map_info
	text += "─────────────────────\n"
	text += "[color=gray]WASD=move Shift=sprint C=crouch\n"
	text += "Space=jump Tab=camera 1-5=NPC F1=HUD\n"
	text += "F2=dump KF comparison[/color]"

	_debug_hud.text = text


# =============================================================================
# PIPELINE DIAGNOSTIC (runs once after NPC spawn)
# =============================================================================

func _dump_pipeline_diagnostic() -> void:
	if not _player_controller:
		return

	Log.info("testing", "")
	Log.info("testing", "====== ANIMATION PIPELINE DIAGNOSTIC ======")

	# 1. Check skeleton
	var skeleton: Skeleton3D = _find_skeleton(_player_controller)
	if not skeleton:
		Log.error("testing", "DIAG: No Skeleton3D found in player controller!")
		return
	Log.info("testing", "Skeleton: %d bones, first 5: %s" % [
		skeleton.get_bone_count(),
		str(_get_bone_names(skeleton).slice(0, 5))])

	# 2. Check AnimationPlayer
	var anim_player: AnimationPlayer = null
	for child in _player_controller.get_children():
		anim_player = _find_anim_player_recursive(child)
		if anim_player:
			break
	if not anim_player:
		Log.error("testing", "DIAG: No AnimationPlayer found!")
		return
	var anims := anim_player.get_animation_list()
	Log.info("testing", "AnimationPlayer: %d animations, root_node=%s, path=%s" % [
		anims.size(), str(anim_player.root_node),
		str(anim_player.get_path())])
	Log.info("testing", "  Animations: %s" % ", ".join(anims))

	# Check track paths of first animation
	if anims.size() > 0:
		var first_anim: Animation = anim_player.get_animation(anims[0])
		var sample_tracks := PackedStringArray()
		for i in mini(first_anim.get_track_count(), 5):
			sample_tracks.append(str(first_anim.track_get_path(i)))
		Log.info("testing", "  Sample tracks from '%s': %s" % [anims[0], ", ".join(sample_tracks)])

	# Verify track bones match skeleton
	var bone_names := _get_bone_names(skeleton)
	if anims.size() > 0:
		var test_anim := anim_player.get_animation(anims[0])
		var matched := 0
		var unmatched := PackedStringArray()
		for track_idx in test_anim.get_track_count():
			var path := test_anim.track_get_path(track_idx)
			if path.get_subname_count() > 0:
				var track_bone := String(path.get_subname(0))
				if track_bone in bone_names:
					matched += 1
				elif unmatched.size() < 5:
					unmatched.append(track_bone)
		Log.info("testing", "  Track-to-skeleton match: %d matched, %d unmatched %s" % [
			matched, unmatched.size(),
			"(%s)" % ", ".join(unmatched) if unmatched.size() > 0 else ""])

	# 3. Check AnimationTree
	var anim_tree: AnimationTree = null
	for child in skeleton.get_children():
		if child is AnimationTree:
			anim_tree = child as AnimationTree
			break
	if not anim_tree:
		Log.warn("testing", "DIAG: No AnimationTree on skeleton!")
	else:
		Log.info("testing", "AnimationTree: active=%s, anim_player=%s" % [
			str(anim_tree.active), str(anim_tree.anim_player)])
		var sm = anim_tree.get("parameters/locomotion/playback")
		if sm:
			Log.info("testing", "  StateMachine current node: '%s'" % str(sm.get_current_node()))
		else:
			Log.warn("testing", "  StateMachine playback: NOT FOUND (path: parameters/locomotion/playback)")

	# 4. Check animation system (CharacterAnimationSystem)
	var anim_sys = _player_controller.animation_system
	if not anim_sys:
		Log.warn("testing", "DIAG: No animation_system on player controller!")
	else:
		Log.info("testing", "AnimationSystem: type=%s" % anim_sys.get_class())
		var am = anim_sys.get("animation_manager")
		if am:
			var smap = am.get("_state_animation_map")
			if smap and smap is Dictionary:
				var entries := PackedStringArray()
				for key in smap:
					entries.append("%s->%s" % [key, smap[key]])
				Log.info("testing", "  State map: %s" % ", ".join(entries))
			else:
				Log.warn("testing", "  State map: EMPTY or not found")
		else:
			Log.warn("testing", "  AnimationManager: NOT FOUND")

	# 5. Check for multiple AnimationTrees (common bug: two trees fighting)
	var tree_count := _count_anim_trees(_player_controller)
	if tree_count > 1:
		Log.error("testing", "DIAG: FOUND %d AnimationTrees — they're fighting for bone control!" % tree_count)
	else:
		Log.info("testing", "AnimationTree count: %d (expect 1)" % tree_count)

	# 6. Quick bone pose check — are bones in rest pose or animated?
	var non_identity := 0
	for i in skeleton.get_bone_count():
		var rot := skeleton.get_bone_pose_rotation(i)
		if rot.angle_to(Quaternion.IDENTITY) > 0.01:
			non_identity += 1
	Log.info("testing", "Bone pose check: %d/%d bones have non-identity rotation (expect >10 if animated)" % [
		non_identity, skeleton.get_bone_count()])

	Log.info("testing", "====== END PIPELINE DIAGNOSTIC ======")
	Log.info("testing", "")


func _get_bone_names(skel: Skeleton3D) -> PackedStringArray:
	var names := PackedStringArray()
	for i in skel.get_bone_count():
		names.append(skel.get_bone_name(i))
	return names


func _count_anim_trees(node: Node) -> int:
	var count := 1 if node is AnimationTree else 0
	for child in node.get_children():
		count += _count_anim_trees(child)
	return count


# =============================================================================
# KF vs ACTUAL BONE COMPARISON (F2)
# =============================================================================

func _dump_kf_comparison() -> void:
	if not _player_controller:
		Log.warn("testing", "KF COMPARE: No player controller")
		return

	# Find skeleton inside player controller
	var skeleton: Skeleton3D = _find_skeleton(_player_controller)
	if not skeleton:
		Log.warn("testing", "KF COMPARE: No skeleton found")
		return

	# Find AnimationPlayer
	var anim_player: AnimationPlayer = null
	for child in _player_controller.get_children():
		anim_player = _find_anim_player_recursive(child)
		if anim_player:
			break
	if not anim_player:
		Log.warn("testing", "KF COMPARE: No AnimationPlayer found")
		return

	# Find AnimationTree
	var anim_tree: AnimationTree = null
	for child in skeleton.get_children():
		if child is AnimationTree:
			anim_tree = child as AnimationTree
			break

	Log.info("testing", "")
	Log.info("testing", "====== KF vs ACTUAL BONE COMPARISON ======")
	Log.info("testing", "AnimationPlayer: %d anims, root=%s" % [
		anim_player.get_animation_list().size(),
		str(anim_player.root_node)])
	if anim_tree:
		Log.info("testing", "AnimationTree: active=%s, anim_player=%s" % [
			str(anim_tree.active), str(anim_tree.anim_player)])
		var sm = anim_tree.get("parameters/locomotion/playback")
		if sm:
			Log.info("testing", "StateMachine node: %s" % str(sm.get_current_node()))
	else:
		Log.info("testing", "AnimationTree: NOT FOUND")

	# Get the Idle animation's expected bone values
	var idle_anim: Animation = null
	for anim_name in anim_player.get_animation_list():
		if anim_name.to_lower() == "idle":
			idle_anim = anim_player.get_animation(anim_name)
			Log.info("testing", "Using animation: '%s'" % anim_name)
			break

	if not idle_anim:
		Log.warn("testing", "KF COMPARE: No 'Idle' animation found")
		Log.info("testing", "Available: %s" % ", ".join(anim_player.get_animation_list()))
		return

	# Compare first keyframe of each bone track vs actual skeleton pose
	Log.info("testing", "%-20s | %-40s | %-40s | %s" % [
		"BONE", "KF ROTATION (t=0)", "ACTUAL ROTATION", "MATCH?"])
	Log.info("testing", "-".repeat(130))

	var match_count := 0
	var total := 0
	for track_idx in idle_anim.get_track_count():
		var path := idle_anim.track_get_path(track_idx)
		if path.get_subname_count() == 0:
			continue
		var bone_name := String(path.get_subname(0))
		var bone_idx := skeleton.find_bone(bone_name)
		if bone_idx < 0:
			Log.warn("testing", "  Bone '%s' not in skeleton" % bone_name)
			continue

		var track_type := idle_anim.track_get_type(track_idx)
		if track_type == Animation.TYPE_ROTATION_3D:
			total += 1
			var kf_rot: Quaternion = idle_anim.track_get_key_value(track_idx, 0) as Quaternion
			var actual_rot: Quaternion = skeleton.get_bone_pose_rotation(bone_idx)
			var angle_diff := kf_rot.angle_to(actual_rot)
			var matches := angle_diff < 0.05  # ~3 degrees
			if matches:
				match_count += 1
			Log.info("testing", "%-20s | (%.3f, %.3f, %.3f, %.3f) | (%.3f, %.3f, %.3f, %.3f) | %s (%.1f deg)" % [
				bone_name,
				kf_rot.x, kf_rot.y, kf_rot.z, kf_rot.w,
				actual_rot.x, actual_rot.y, actual_rot.z, actual_rot.w,
				"OK" if matches else "MISMATCH",
				rad_to_deg(angle_diff)])
		elif track_type == Animation.TYPE_POSITION_3D:
			var kf_pos: Vector3 = idle_anim.track_get_key_value(track_idx, 0) as Vector3
			var actual_pos: Vector3 = skeleton.get_bone_pose_position(bone_idx)
			var dist := kf_pos.distance_to(actual_pos)
			Log.info("testing", "%-20s | pos (%.3f, %.3f, %.3f) | pos (%.3f, %.3f, %.3f) | %s (%.3f)" % [
				bone_name,
				kf_pos.x, kf_pos.y, kf_pos.z,
				actual_pos.x, actual_pos.y, actual_pos.z,
				"OK" if dist < 0.01 else "MISMATCH", dist])

	Log.info("testing", "")
	Log.info("testing", "RESULT: %d/%d rotation tracks match actual pose" % [match_count, total])
	Log.info("testing", "====== END KF COMPARISON ======")
	Log.info("testing", "")


func _find_anim_player_recursive(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var result := _find_anim_player_recursive(child)
		if result:
			return result
	return null


# =============================================================================
# HELPERS
# =============================================================================

func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node as Skeleton3D
	for child in node.get_children():
		var result := _find_skeleton(child)
		if result:
			return result
	return null


func _diagnose_animation_binding(char_root: Node3D, skel: Skeleton3D) -> void:
	# Collect skeleton bone names
	var bone_names := PackedStringArray()
	for i in skel.get_bone_count():
		bone_names.append(skel.get_bone_name(i))
	Log.info("testing", "DIAG: Skeleton has %d bones. First 5: %s" % [
		bone_names.size(), str(bone_names.slice(0, 5))])

	# Find AnimationPlayer
	var anim_player: AnimationPlayer = null
	for child in char_root.get_children():
		if child is AnimationPlayer:
			anim_player = child as AnimationPlayer
			break
	if not anim_player:
		for child in skel.get_children():
			if child is AnimationPlayer:
				anim_player = child as AnimationPlayer
				break
	if not anim_player:
		Log.warn("testing", "DIAG: No AnimationPlayer found!")
		return

	# Check animation count
	var anims := anim_player.get_animation_list()
	Log.info("testing", "DIAG: AnimationPlayer has %d animations. First 5: %s" % [
		anims.size(), str(anims.slice(0, 5))])
	# Dump all animation names for debugging state machine mapping
	Log.info("testing", "DIAG: All animations: %s" % ", ".join(anims))

	# Check track paths of 'idle' animation
	var test_anim_name := ""
	for a in anims:
		if a.to_lower() == "idle":
			test_anim_name = a
			break
	if test_anim_name.is_empty() and anims.size() > 0:
		test_anim_name = anims[0]

	if test_anim_name.is_empty():
		Log.warn("testing", "DIAG: No animations to inspect!")
		return

	var anim: Animation = anim_player.get_animation(test_anim_name)
	var matched := 0
	var unmatched := 0
	var unmatched_names := PackedStringArray()
	for track_idx in anim.get_track_count():
		var path := anim.track_get_path(track_idx)
		if path.get_subname_count() > 0:
			var track_bone := String(path.get_subname(0))
			if track_bone in bone_names:
				matched += 1
			else:
				unmatched += 1
				if unmatched_names.size() < 5:
					unmatched_names.append(track_bone)

	Log.info("testing", "DIAG: Animation '%s' — %d tracks match skeleton, %d DON'T match" % [
		test_anim_name, matched, unmatched])
	if unmatched > 0:
		Log.warn("testing", "DIAG: Unmatched track bones: %s" % str(unmatched_names))


func _update_bone_attachment_names(skeleton: Skeleton3D, rename_map: Dictionary) -> void:
	for child in skeleton.get_children():
		if child is BoneAttachment3D:
			var att: BoneAttachment3D = child as BoneAttachment3D
			var old_name := att.bone_name
			if rename_map.has(old_name):
				att.bone_name = rename_map[old_name]
