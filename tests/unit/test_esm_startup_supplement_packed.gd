extends GdUnitTestSuite

const ESMManagerScript := preload("res://src/core/esm/esm_manager.gd")


func test_packed_startup_supplement_populates_and_removes_records() -> void:
	var manager := ESMManagerScript.new()
	var stale_book := BookRecord.new()
	stale_book.record_id = "old_note"
	stale_book.name = "Stale"
	manager._store_record(stale_book, ESMDefs.RecordType.REC_BOOK)

	var data := _empty_startup_supplement()
	data["book_keys"] = PackedStringArray(["old_note", "bk_note"])
	data["book_record_ids"] = PackedStringArray(["old_note", "bk_note"])
	data["book_models"] = PackedStringArray(["", "m\\book.nif"])
	data["book_deleted"] = PackedByteArray([1, 0])
	data["book_names"] = PackedStringArray(["", "Readable Note"])
	data["book_icons"] = PackedStringArray(["", "icon_note.dds"])
	data["book_scripts"] = PackedStringArray(["", "note_script"])
	data["book_enchant_ids"] = PackedStringArray(["", ""])
	data["book_texts"] = PackedStringArray(["", "Body text"])
	data["book_weights"] = PackedFloat32Array([0.0, 1.5])
	data["book_values"] = PackedInt32Array([0, 25])
	data["book_scrolls"] = PackedByteArray([0, 1])
	data["book_skill_ids"] = PackedInt32Array([-1, 3])
	data["book_enchant_points"] = PackedInt32Array([0, 7])
	data["dialogue_keys"] = PackedStringArray(["topic_a"])
	data["dialogue_record_ids"] = PackedStringArray(["topic_a"])
	data["dialogue_deleted"] = PackedByteArray([0])
	data["dialogue_types"] = PackedInt32Array([1])
	data["info_topics"] = PackedStringArray(["topic_a"])
	data["info_counts"] = PackedInt32Array([2])
	data["info_record_ids"] = PackedStringArray(["info_deleted", "info_live"])
	data["info_deleted"] = PackedByteArray([1, 0])
	data["info_prev_ids"] = PackedStringArray(["", "prev"])
	data["info_next_ids"] = PackedStringArray(["", "next"])
	data["info_dispositions"] = PackedInt32Array([0, 42])
	data["info_speaker_ranks"] = PackedInt32Array([-1, 2])
	data["info_speaker_sexes"] = PackedInt32Array([-1, 1])
	data["info_player_ranks"] = PackedInt32Array([-1, 3])
	data["info_actor_ids"] = PackedStringArray(["", "actor"])
	data["info_actor_races"] = PackedStringArray(["", "race"])
	data["info_actor_classes"] = PackedStringArray(["", "class"])
	data["info_actor_factions"] = PackedStringArray(["", "faction"])
	data["info_actor_cells"] = PackedStringArray(["", "cell"])
	data["info_pc_factions"] = PackedStringArray(["", "pc_faction"])
	data["info_sound_files"] = PackedStringArray(["", "sound"])
	data["info_responses"] = PackedStringArray(["", "response"])
	data["info_result_scripts"] = PackedStringArray(["", "result"])
	data["info_quest_names"] = PackedByteArray([0, 1])
	data["info_quest_finishes"] = PackedByteArray([0, 1])
	data["info_quest_restarts"] = PackedByteArray([0, 0])
	data["info_conditions"] = [{}, [{"raw": "cond", "int_value": 5}]]
	data["levc_keys"] = PackedStringArray(["lev_creature"])
	data["levc_record_ids"] = PackedStringArray(["lev_creature"])
	data["levc_deleted"] = PackedByteArray([0])
	data["levc_flags"] = PackedInt32Array([4])
	data["levc_chance_none"] = PackedInt32Array([12])
	data["levc_creatures"] = [[{"id": "rat", "level": 1}]]

	manager._populate_startup_supplement_from_packed(data)

	assert_bool(manager.books.has("old_note")).is_false()
	assert_bool(manager.books.has("bk_note")).is_true()
	var book: BookRecord = manager.books["bk_note"]
	assert_str(book.name).is_equal("Readable Note")
	assert_bool(book.is_scroll).is_true()
	assert_int(book.value).is_equal(25)
	assert_bool(manager.dialogues.has("topic_a")).is_true()
	assert_bool(manager.dialogue_infos.has("topic_a")).is_true()
	assert_int(manager.dialogue_infos["topic_a"].size()).is_equal(1)
	var info: DialogueInfoRecord = manager.dialogue_infos["topic_a"][0]
	assert_str(info.record_id).is_equal("info_live")
	assert_bool(info.quest_finish).is_true()
	assert_array(info.conditions).contains([{"raw": "cond", "int_value": 5}])
	assert_bool(manager.leveled_creatures.has("lev_creature")).is_true()
	assert_int(manager.leveled_creatures["lev_creature"].chance_none).is_equal(12)


func _empty_startup_supplement() -> Dictionary:
	return {
		"book_keys": PackedStringArray(),
		"book_record_ids": PackedStringArray(),
		"book_models": PackedStringArray(),
		"book_deleted": PackedByteArray(),
		"book_names": PackedStringArray(),
		"book_icons": PackedStringArray(),
		"book_scripts": PackedStringArray(),
		"book_enchant_ids": PackedStringArray(),
		"book_texts": PackedStringArray(),
		"book_weights": PackedFloat32Array(),
		"book_values": PackedInt32Array(),
		"book_scrolls": PackedByteArray(),
		"book_skill_ids": PackedInt32Array(),
		"book_enchant_points": PackedInt32Array(),
		"class_keys": PackedStringArray(),
		"class_record_ids": PackedStringArray(),
		"class_deleted": PackedByteArray(),
		"class_names": PackedStringArray(),
		"class_descriptions": PackedStringArray(),
		"class_primary_attributes": PackedInt32Array(),
		"class_specializations": PackedInt32Array(),
		"class_major_skills": PackedInt32Array(),
		"class_minor_skills": PackedInt32Array(),
		"class_playable": PackedByteArray(),
		"class_services": PackedInt32Array(),
		"faction_keys": PackedStringArray(),
		"faction_record_ids": PackedStringArray(),
		"faction_deleted": PackedByteArray(),
		"faction_names": PackedStringArray(),
		"faction_rank_names": [],
		"faction_favorite_attributes": PackedInt32Array(),
		"faction_rank_data": [],
		"faction_favorite_skills": PackedInt32Array(),
		"faction_hidden": PackedByteArray(),
		"faction_reactions": [],
		"skill_keys": PackedStringArray(),
		"skill_record_ids": PackedStringArray(),
		"skill_deleted": PackedByteArray(),
		"skill_descriptions": PackedStringArray(),
		"skill_attributes": PackedInt32Array(),
		"skill_specializations": PackedInt32Array(),
		"skill_use_values": PackedFloat32Array(),
		"birthsign_keys": PackedStringArray(),
		"birthsign_record_ids": PackedStringArray(),
		"birthsign_deleted": PackedByteArray(),
		"birthsign_names": PackedStringArray(),
		"birthsign_descriptions": PackedStringArray(),
		"birthsign_textures": PackedStringArray(),
		"birthsign_powers": [],
		"dialogue_keys": PackedStringArray(),
		"dialogue_record_ids": PackedStringArray(),
		"dialogue_deleted": PackedByteArray(),
		"dialogue_types": PackedInt32Array(),
		"info_topics": PackedStringArray(),
		"info_counts": PackedInt32Array(),
		"info_record_ids": PackedStringArray(),
		"info_deleted": PackedByteArray(),
		"info_prev_ids": PackedStringArray(),
		"info_next_ids": PackedStringArray(),
		"info_dispositions": PackedInt32Array(),
		"info_speaker_ranks": PackedInt32Array(),
		"info_speaker_sexes": PackedInt32Array(),
		"info_player_ranks": PackedInt32Array(),
		"info_actor_ids": PackedStringArray(),
		"info_actor_races": PackedStringArray(),
		"info_actor_classes": PackedStringArray(),
		"info_actor_factions": PackedStringArray(),
		"info_actor_cells": PackedStringArray(),
		"info_pc_factions": PackedStringArray(),
		"info_sound_files": PackedStringArray(),
		"info_responses": PackedStringArray(),
		"info_result_scripts": PackedStringArray(),
		"info_quest_names": PackedByteArray(),
		"info_quest_finishes": PackedByteArray(),
		"info_quest_restarts": PackedByteArray(),
		"info_conditions": [],
		"levc_keys": PackedStringArray(),
		"levc_record_ids": PackedStringArray(),
		"levc_deleted": PackedByteArray(),
		"levc_flags": PackedInt32Array(),
		"levc_chance_none": PackedInt32Array(),
		"levc_creatures": [],
	}
