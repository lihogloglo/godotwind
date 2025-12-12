## NanoID generator wrapper - delegates to PandoraNanoIDGenerator
## This avoids duplicating the same nanoid implementation across addons
class_name QuestifyNanoIdGenerator extends RefCounted


const DEFAULT_LENGTH := 21

## Shared generator instance (lazy initialization)
static var _generator: PandoraNanoIDGenerator = null


static func generate(length := DEFAULT_LENGTH) -> String:
	if _generator == null:
		_generator = PandoraNanoIDGenerator.new(length)
	return _generator.generate(length)
