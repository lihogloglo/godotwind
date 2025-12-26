## Test script for the new animation system
##
## Run with: godot --headless --script "res://test_animation_system.gd"
extends SceneTree

# Preload all classes
const CharacterAnimationSystemClass := preload("res://src/core/animation/character_animation_system.gd")
const AnimationManagerClass := preload("res://src/core/animation/animation_manager.gd")
const IKControllerClass := preload("res://src/core/animation/ik_controller.gd")
const ProceduralModifierControllerClass := preload("res://src/core/animation/procedural_modifier_controller.gd")
const AnimationLODControllerClass := preload("res://src/core/animation/animation_lod_controller.gd")
const HumanoidAnimationSystemClass := preload("res://src/core/animation/humanoid_animation_system.gd")
const MorrowindCharacterSystemClass := preload("res://src/core/animation/morrowind_character_system.gd")
const CreatureAnimationSystemClass := preload("res://src/core/animation/creature_animation_system.gd")
const CharacterFactoryV2Class := preload("res://src/core/animation/character_factory_v2.gd")


func _init() -> void:
	print("=" .repeat(60))
	print("Animation System Test")
	print("=" .repeat(60))

	# Test 1: Class loading
	print("\n[Test 1] Loading animation system classes...")
	_test_class_loading()

	# Test 2: Bone mapping
	print("\n[Test 2] Testing Morrowind bone mapping...")
	_test_bone_mapping()

	# Test 3: Animation state mapping
	print("\n[Test 3] Testing animation state mapping...")
	_test_animation_mapping()

	# Test 4: Class hierarchy
	print("\n[Test 4] Testing class hierarchy...")
	_test_class_hierarchy()

	print("\n" + "=" .repeat(60))
	print("All tests completed!")
	print("=" .repeat(60))

	quit()


func _test_class_loading() -> void:
	# Test that all classes can be instantiated
	var tests := [
		["CharacterAnimationSystem", CharacterAnimationSystemClass],
		["AnimationManager", AnimationManagerClass],
		["IKController", IKControllerClass],
		["ProceduralModifierController", ProceduralModifierControllerClass],
		["AnimationLODController", AnimationLODControllerClass],
		["HumanoidAnimationSystem", HumanoidAnimationSystemClass],
		["MorrowindCharacterSystem", MorrowindCharacterSystemClass],
		["CreatureAnimationSystem", CreatureAnimationSystemClass],
		["CharacterFactoryV2", CharacterFactoryV2Class],
	]

	for test: Array in tests:
		var class_name_str: String = test[0]
		var class_ref: GDScript = test[1]

		var instance: Object = class_ref.new()

		if instance:
			print("  [OK] %s" % class_name_str)
			if instance is Node:
				(instance as Node).queue_free()
		else:
			print("  [FAIL] %s - could not instantiate" % class_name_str)


func _test_bone_mapping() -> void:
	# Test Morrowind bone name mapping
	var test_bones := {
		"Bip01": &"Hips",
		"Bip01 Spine": &"Spine",
		"Bip01 Head": &"Head",
		"Bip01 L Thigh": &"LeftUpperLeg",
		"Bip01 R Foot": &"RightFoot",
		"Bip01 L Hand": &"LeftHand",
	}

	var bone_map: Dictionary = MorrowindCharacterSystemClass.MORROWIND_BONE_MAP

	for morrowind_name: String in test_bones:
		var expected: StringName = test_bones[morrowind_name]
		var mapped: Variant = bone_map.get(morrowind_name)

		if mapped == null:
			# Try lowercase
			mapped = bone_map.get(morrowind_name.to_lower())

		if mapped != null and mapped == expected:
			print("  [OK] '%s' -> '%s'" % [morrowind_name, mapped])
		else:
			print("  [FAIL] '%s' expected '%s' got '%s'" % [morrowind_name, expected, mapped])


func _test_animation_mapping() -> void:
	# Test animation state mapping
	var test_states := {
		&"Idle": ["idle", "Idle"],
		&"Walk": ["walkforward", "WalkForward", "walk"],
		&"Run": ["runforward", "RunForward", "run"],
		&"Attack": ["attack1", "Attack1", "attackchop1"],
	}

	var anim_map: Dictionary = MorrowindCharacterSystemClass.MORROWIND_ANIM_MAP

	for state: StringName in test_states:
		var expected_terms: Array = test_states[state]
		var actual_terms: Variant = anim_map.get(state)

		if actual_terms != null:
			var match_count := 0
			for term: String in expected_terms:
				if term in (actual_terms as Array):
					match_count += 1

			if match_count == expected_terms.size():
				print("  [OK] State '%s' has all expected terms" % state)
			else:
				print("  [PARTIAL] State '%s' matched %d/%d terms" % [state, match_count, expected_terms.size()])
		else:
			print("  [FAIL] State '%s' not found in mapping" % state)


func _test_class_hierarchy() -> void:
	# Test inheritance chain
	var morrowind := MorrowindCharacterSystemClass.new()
	var humanoid := HumanoidAnimationSystemClass.new()
	var creature := CreatureAnimationSystemClass.new()
	var base := CharacterAnimationSystemClass.new()

	# Test MorrowindCharacterSystem extends HumanoidAnimationSystem
	if morrowind is HumanoidAnimationSystemClass:
		print("  [OK] MorrowindCharacterSystem extends HumanoidAnimationSystem")
	else:
		print("  [FAIL] MorrowindCharacterSystem should extend HumanoidAnimationSystem")

	# Test HumanoidAnimationSystem extends CharacterAnimationSystem
	if humanoid is CharacterAnimationSystemClass:
		print("  [OK] HumanoidAnimationSystem extends CharacterAnimationSystem")
	else:
		print("  [FAIL] HumanoidAnimationSystem should extend CharacterAnimationSystem")

	# Test CreatureAnimationSystem extends CharacterAnimationSystem
	if creature is CharacterAnimationSystemClass:
		print("  [OK] CreatureAnimationSystem extends CharacterAnimationSystem")
	else:
		print("  [FAIL] CreatureAnimationSystem should extend CharacterAnimationSystem")

	# Test base class is Node
	if base is Node:
		print("  [OK] CharacterAnimationSystem extends Node")
	else:
		print("  [FAIL] CharacterAnimationSystem should extend Node")

	# Cleanup
	morrowind.queue_free()
	humanoid.queue_free()
	creature.queue_free()
	base.queue_free()
