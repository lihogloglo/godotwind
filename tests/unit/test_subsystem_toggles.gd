extends GdUnitTestSuite

const SubsystemTogglesScript := preload("res://src/tools/subsystem_toggles.gd")


func test_setup_applies_true_and_false_defaults() -> void:
	var applied: Dictionary = {}
	var toggles := SubsystemTogglesScript.new()
	toggles.setup(
		{
			"impostors": func(on: bool) -> void: applied["impostors"] = on,
			"hlod": func(on: bool) -> void: applied["hlod"] = on,
			"ocean": func(on: bool) -> void: applied["ocean"] = on,
		},
		{
			"impostors": true,
			"hlod": true,
			"ocean": false,
		}
	)

	assert_dict(applied).contains_key_value("impostors", true)
	assert_dict(applied).contains_key_value("hlod", true)
	assert_dict(applied).contains_key_value("ocean", false)
