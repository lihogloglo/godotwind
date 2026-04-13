## BookInteractable — Morrowind book adapter for the Interactable framework
##
## Attach to a streamed book world object (Node3D with a mesh and a
## StaticBody3D on collision layer 3). When the player presses the
## "interact" action within range, opens the BookViewer with the book's
## contents.
##
## ## Framework/adapter boundary
##
## Lives in the `morrowind/` subdirectory because it reads from ESMManager
## and knows about BookRecord. The Interactable base class it extends is
## fully generic.
##
## ## Shared references
##
## BookViewer is NOT stored per-instance — it lives in `DialogueSession.current()`,
## set once at boot by the main scene. `interact()` pulls it at the moment of use.
##
## ## Usage
##
## ```gdscript
## var book_node := <spawned book Node3D>
## var interactable := BookInteractable.new()
## interactable.book_id = "book_text_clsg"
## book_node.add_child(interactable)
## ```
class_name BookInteractable
extends Interactable

## ESM book identifier (record_id, lowercase).
@export var book_id: String = ""


var _cached_book: BookRecord = null


func _ready() -> void:
	if book_id.is_empty():
		Log.warn("dialogue", "BookInteractable has no book_id")


## Override: show the book title (or "Scroll" for scrolls) in the prompt.
func get_prompt_text() -> String:
	var book := _get_book_record()
	if book == null:
		return "Read %s" % book_id
	var verb := "Read"
	if book.is_scroll:
		verb = "Unroll"
	var title := book.name if not book.name.is_empty() else book.record_id
	return "%s %s" % [verb, title]


## Override: open the BookViewer with this book.
func interact(player: Node3D) -> void:
	var session := DialogueSession.current()
	if session == null:
		Log.warn("dialogue", "BookInteractable.interact(): DialogueSession.current() is null — main scene must call DialogueSession.set_current() at boot")
		return
	if session.book_viewer == null:
		Log.warn("dialogue", "BookInteractable.interact(): session.book_viewer is null")
		return
	var book := _get_book_record()
	if book == null:
		Log.warn("dialogue", "BookInteractable: book '%s' not found in ESM" % book_id)
		return
	var title := book.name if not book.name.is_empty() else book.record_id
	session.book_viewer.show_book(title, book.text)
	# Fire the base class signal so any raycaster listeners can react
	super.interact(player)


## Lookup + cache the BookRecord for this book.
func _get_book_record() -> BookRecord:
	if _cached_book != null:
		return _cached_book
	if book_id.is_empty():
		return null
	_cached_book = ESMManager.get_book(book_id)
	return _cached_book
