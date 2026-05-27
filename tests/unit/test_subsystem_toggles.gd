extends GdUnitTestSuite

const SubsystemTogglesScript := preload("res://src/tools/subsystem_toggles.gd")


func test_setup_applies_true_and_false_defaults() -> void:
	var applied: Dictionary = {}
	var toggles := SubsystemTogglesScript.new()
	toggles.setup(
		{
			"far_impostors": func(on: bool) -> void: applied["far_impostors"] = on,
			"hlod": func(on: bool) -> void: applied["hlod"] = on,
			"ocean": func(on: bool) -> void: applied["ocean"] = on,
		},
		{
			"far_impostors": true,
			"hlod": true,
			"ocean": false,
		}
	)

	assert_dict(applied).contains_key_value("far_impostors", true)
	assert_dict(applied).contains_key_value("hlod", true)
	assert_dict(applied).contains_key_value("ocean", false)


func test_alias_routes_to_canonical_flag() -> void:
	var applied: Dictionary = {}
	var toggles := SubsystemTogglesScript.new()
	toggles.setup(
		{"far_impostors": func(on: bool) -> void: applied["far_impostors"] = on},
		{"far_impostors": true}
	)
	toggles.register_alias("impostors", "far_impostors")
	toggles.set_flag("impostors", false)
	assert_bool(toggles.get_flag("far_impostors")).is_false()
	assert_bool(toggles.get_flag("impostors")).is_false()
	assert_dict(applied).contains_key_value("far_impostors", false)


func test_flag_changed_emits_canonical_name_for_ui_sync() -> void:
	var changed_name := ""
	var changed_enabled := true
	var toggles := SubsystemTogglesScript.new()
	toggles.setup(
		{"hlod": func(_on: bool) -> void: pass},
		{"hlod": false}
	)
	toggles.flag_changed.connect(func(name: String, enabled: bool) -> void:
		changed_name = name
		changed_enabled = enabled
	)

	toggles.set_flag("hlod", true)

	assert_str(changed_name).is_equal("hlod")
	assert_bool(changed_enabled).is_true()
