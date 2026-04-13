## MWResultScriptHandler — Morrowind dialogue result script (BNAM) interpreter
##
## Executes the subset of MW scripting language found in dialogue INFO result
## scripts. Connects to DialogueUI signals (response_selected, greeting_shown)
## and reads the result_script from Response.metadata.
##
## ## Architecture
##
## Commands that modify dialogue state (Journal, AddTopic, ModDisposition,
## set...to, Goodbye, ForceGreeting) are executed directly. Commands that
## affect external game systems (AddItem, PlaySound, RaiseRank, etc.) are
## forwarded via the `script_command` signal for external consumers to handle.
##
## ## Framework/adapter boundary
##
## Lives in morrowind/ because it parses MW script syntax. The framework
## (DialogueUI, DialogueProvider, QuestManager) has zero knowledge of BNAM.
## The metadata dict on Response is the extension point.
##
## ## Wiring
##
## ```gdscript
## var handler := MWResultScriptHandler.new(quest_manager, context)
## dialogue_ui.response_selected.connect(handler.on_response_selected)
## dialogue_ui.greeting_shown.connect(handler.on_greeting_shown)
## handler.goodbye_requested.connect(dialogue_ui.close)
## handler.force_greeting_requested.connect(func():
##     dialogue_ui.close()
##     dialogue_ui.open(provider, speaker_id, context)
## )
## ```
class_name MWResultScriptHandler
extends RefCounted

## Emitted for commands that affect external game systems.
## Consumers connect once and dispatch by command name.
## args is Array of parsed argument values (String or float).
signal script_command(command: String, args: Array)

## Dialogue flow control signals.
signal goodbye_requested()
signal force_greeting_requested()

## Choice presented to the player: Array of {text: String, choice_id: int}.
signal choice_presented(options: Array)


var _quest_manager: QuestManager
var _context: DialogueContext

## Speaker ID of the current conversation (set by greeting/response handlers).
var _current_speaker_id: String = ""


func _init(quest_manager: QuestManager, context: DialogueContext) -> void:
	_quest_manager = quest_manager
	_context = context


## Signal handler for DialogueUI.response_selected.
func on_response_selected(_topic_id: String, response: DialogueProvider.Response) -> void:
	_execute_from_response(response)


## Signal handler for DialogueUI.greeting_shown.
func on_greeting_shown(speaker_id: String, response: DialogueProvider.Response) -> void:
	_current_speaker_id = speaker_id
	_execute_from_response(response)


## Extract result_script from metadata and execute.
func _execute_from_response(response: DialogueProvider.Response) -> void:
	if not response.ok() or response.metadata.is_empty():
		return
	var script_text: String = response.metadata.get("result_script", "")
	if script_text.is_empty():
		return
	execute(script_text)


## Parse and execute a MW result script (one or more lines).
func execute(script_text: String) -> void:
	var lines := script_text.split("\n", false)
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with(";"):
			continue
		_execute_line(trimmed)


## Execute a single script line.
func _execute_line(line: String) -> void:
	var tokens := _tokenize(line)
	if tokens.is_empty():
		return

	var cmd: String = tokens[0].to_lower()
	var args := tokens.slice(1)

	match cmd:
		"journal":
			_cmd_journal(args)
		"addtopic":
			_cmd_add_topic(args)
		"moddisposition":
			_cmd_mod_disposition(args)
		"setdisposition":
			_cmd_set_disposition(args)
		"set":
			_cmd_set_global(args)
		"goodbye":
			goodbye_requested.emit()
		"forcegreeting":
			force_greeting_requested.emit()
		"choice":
			_cmd_choice(args)
		"additem":
			_cmd_forward("AddItem", args, 2)
		"removeitem":
			_cmd_forward("RemoveItem", args, 2)
		"addspell":
			_cmd_forward("AddSpell", args, 1)
		"removespell":
			_cmd_forward("RemoveSpell", args, 1)
		"raiserank":
			script_command.emit("RaiseRank", [])
		"lowerrank":
			script_command.emit("LowerRank", [])
		"playsound":
			_cmd_forward("PlaySound", args, 1)
		"playsound3d":
			_cmd_forward("PlaySound3D", args, 1)
		"startcombat":
			_cmd_forward("StartCombat", args, 1)
		"stopcombat":
			script_command.emit("StopCombat", [])
		"aitravel":
			_cmd_forward("AiTravel", args, 3)
		"aifollow":
			script_command.emit("AiFollow", args)
		"messagebox":
			_cmd_forward("MessageBox", args, 1)
		_:
			Log.debug("dialogue", "BNAM: unhandled command '%s' (full line: %s)" % [cmd, line])


# -- Direct execution commands ------------------------------------------------

func _cmd_journal(args: Array) -> void:
	if args.size() < 2:
		Log.warn("dialogue", "BNAM Journal: expected 2 args, got %d" % args.size())
		return
	var quest_id: String = args[0]
	var index := _to_int(args[1])
	# Update context so future dialogue filters see the new index
	_context.set_journal_index(quest_id, index)
	# QuestManager handles state transitions + signals
	_quest_manager.update_journal(quest_id, index, "", false, false)
	Log.info("dialogue", "BNAM: Journal '%s' %d" % [quest_id, index])


func _cmd_add_topic(args: Array) -> void:
	if args.is_empty():
		Log.warn("dialogue", "BNAM AddTopic: missing topic_id")
		return
	var topic_id: String = args[0]
	_context.add_topic(topic_id)
	Log.info("dialogue", "BNAM: AddTopic '%s'" % topic_id)


func _cmd_mod_disposition(args: Array) -> void:
	if args.is_empty():
		Log.warn("dialogue", "BNAM ModDisposition: missing value")
		return
	var delta := _to_int(args[0])
	_context.disposition = clampi(_context.disposition + delta, 0, 100)
	Log.info("dialogue", "BNAM: ModDisposition %d (now %d)" % [delta, _context.disposition])


func _cmd_set_disposition(args: Array) -> void:
	if args.is_empty():
		Log.warn("dialogue", "BNAM SetDisposition: missing value")
		return
	var value := _to_int(args[0])
	_context.disposition = clampi(value, 0, 100)
	Log.info("dialogue", "BNAM: SetDisposition %d" % value)


func _cmd_set_global(args: Array) -> void:
	# Syntax: set "variable" to value
	# or:     set variable to value
	if args.size() < 3:
		Log.warn("dialogue", "BNAM set: expected 'set var to value', got %d args" % args.size())
		return
	var var_name: String = args[0]
	# args[1] should be "to" — skip it
	var value := _to_float(args[2])
	_context.set_global(var_name, value)
	Log.info("dialogue", "BNAM: set '%s' to %s" % [var_name, value])


func _cmd_choice(args: Array) -> void:
	# Syntax: Choice "text1" id1 "text2" id2 ...
	var options: Array = []
	var i := 0
	while i + 1 < args.size():
		options.append({
			"text": args[i],
			"choice_id": _to_int(args[i + 1]),
		})
		i += 2
	if options.is_empty():
		Log.warn("dialogue", "BNAM Choice: no valid options parsed")
		return
	Log.info("dialogue", "BNAM: Choice with %d options" % options.size())
	choice_presented.emit(options)


# -- Forwarded commands (signal for external consumers) -----------------------

func _cmd_forward(command: String, args: Array, min_args: int) -> void:
	if args.size() < min_args:
		Log.warn("dialogue", "BNAM %s: expected %d+ args, got %d" % [command, min_args, args.size()])
		return
	Log.info("dialogue", "BNAM: %s %s" % [command, " ".join(args)])
	script_command.emit(command, args)


# -- Tokenizer ----------------------------------------------------------------

## Split a script line into tokens. Handles quoted strings and bare words.
static func _tokenize(line: String) -> Array:
	var tokens: Array = []
	var i := 0
	var length := line.length()

	while i < length:
		# Skip whitespace
		while i < length and (line[i] == " " or line[i] == "\t"):
			i += 1
		if i >= length:
			break

		if line[i] == "\"":
			# Quoted string — scan to closing quote
			i += 1  # skip opening quote
			var start := i
			while i < length and line[i] != "\"":
				i += 1
			tokens.append(line.substr(start, i - start))
			if i < length:
				i += 1  # skip closing quote
		elif line[i] == ",":
			# Skip commas (MW scripts sometimes use them as separators)
			i += 1
		else:
			# Bare word/number — scan to whitespace, comma, or quote
			var start := i
			while i < length and line[i] != " " and line[i] != "\t" and line[i] != "," and line[i] != "\"":
				i += 1
			tokens.append(line.substr(start, i - start))

	return tokens


# -- Type helpers -------------------------------------------------------------

static func _to_int(s: String) -> int:
	if s.is_valid_int():
		return s.to_int()
	if s.is_valid_float():
		return int(s.to_float())
	return 0


static func _to_float(s: String) -> float:
	if s.is_valid_float():
		return s.to_float()
	if s.is_valid_int():
		return float(s.to_int())
	return 0.0
