## CarryableBodyFactory — Convert a static instance into a carryable rigid body
##
## Framework class. Given a freshly duplicated model instance that already
## contains a baked `StaticBody3D` (created by the NIF converter or equivalent
## prebake step), swap that body in-place for a `RigidBody3D` carrying the
## same `CollisionShape3D` children, configured per the I.1 contract:
##
## - `collision_layer = Environment | Interactable` (bits 1 + 3)
## - `collision_mask  = Environment | Player`        (bits 1 + 2) — see
##   `docs/INTERACTION_SYSTEM.md` §6.5 for the held-state mask flip
## - `freeze = true`, `freeze_mode = FREEZE_MODE_KINEMATIC` — zero solver
##   cost at rest until something pokes it
## - `mass` = clamped weight (kg)
## - A `PickupInteractable`-shaped child node is attached so the
##   interaction raycaster can target the body
##
## ## Framework/adapter boundary
##
## ZERO game-specific imports. The "what type is carryable" + "how to
## extract mass" decisions live in the adapter (see CarryableRegistry).
## This file only knows about Godot physics nodes and the framework's own
## `Interactable` base.
##
## ## Why in-place swap and not a fresh body
##
## The NIF prototype scene is cached and `duplicate()`d per instance. By
## the time we see the duplicate, the StaticBody3D + CollisionShape3D
## children are already part of the tree (well, sub-tree — not yet inside
## the cell). Reusing the shapes avoids re-walking the NIF and rebuilding
## physics shapes per pickup. We just rebind them under a new parent body.
##
## ## Why not extend the prototype with a RigidBody3D directly
##
## The same NIF can power a non-carryable static (e.g. a sword on a wall
## decoration that's part of architecture) and a carryable instance (the
## same sword model on a table). The carryable decision is per-record,
## not per-mesh — so the prototype must stay neutral and the spawn step
## decides. This is also why the static-renderer fast path is excluded
## upstream in the instantiator.
##
## ## Mass clamping
##
## The 50 kg "too heavy to grab" gameplay cap is enforced by `CarryController`
## (I.3+), NOT here. This factory only clamps to a sane solver range
## `[0.1, 200.0]` to keep Jolt happy with absurd record values.
class_name CarryableBodyFactory
extends RefCounted

## I.5 — preload buoyancy framework. Both classes live in
## `src/core/water/`, both are framework (no game-specific imports),
## both are Godot-stdlib RigidBody3D / Marker3D subclasses. Cross-import
## within `src/core/` is allowed.
const BuoyancyBody3DScript := preload("res://src/core/water/buoyancy_body.gd")
const BuoyancyProbe3DScript := preload("res://src/core/water/buoyancy_probe.gd")
const GameplayPhysicsLayersScript := preload("res://src/core/physics/gameplay_physics_layers.gd")


## Hard solver-sanity clamp. NOT the gameplay grab cap (that's in
## CarryController). See INTERACTION_SYSTEM.md §6.1 + §13 Q4.
const MASS_MIN_KG: float = 0.1
const MASS_MAX_KG: float = 200.0

## Layer bits. Mirrors `project.godot [layer_names.3d_physics]`.
const LAYER_ENVIRONMENT: int = GameplayPhysicsLayersScript.ENVIRONMENT
const LAYER_PLAYER: int = GameplayPhysicsLayersScript.PLAYER
const LAYER_INTERACTABLE: int = GameplayPhysicsLayersScript.INTERACTABLE

const SPAWN_LAYER: int = GameplayPhysicsLayersScript.CARRYABLE_LAYER
const SPAWN_MASK: int = GameplayPhysicsLayersScript.CARRYABLE_MASK


## Convert the first StaticBody3D found inside `instance` into a
## RigidBody3D wrapped in a PickupInteractable parent. Returns the new
## RigidBody3D, or null if no StaticBody3D was found (the model has no
## baked collision — can't be carried). Mutates `instance` in place.
##
## ## Output structure
##
## Before:
## ```
## instance (Node3D, world transform)
## ├─ Mesh (MeshInstance3D)
## ├─ Mesh2 (MeshInstance3D)
## ├─ OmniLight3D (e.g. torch flame)
## └─ CollisionBody (StaticBody3D, identity)
##     └─ Shape (CollisionShape3D)
## ```
## After (I.3 mesh-follow restructure):
## ```
## instance (Node3D, world transform)            ← cell child, unchanged
## └─ Pickup (PickupInteractable, identity)      ← inserted at the old body's index
##     └─ CollisionBody (RigidBody3D, identity)  ← was StaticBody3D
##         ├─ Mesh (MeshInstance3D)              ← reparented from instance
##         ├─ Mesh2 (MeshInstance3D)             ← reparented from instance
##         ├─ OmniLight3D                        ← reparented from instance (held torch flame follows)
##         └─ Shape (CollisionShape3D)           ← reparented from old StaticBody3D
## ```
##
## ## Why the Interactable must be the body's PARENT
##
## `InteractionRaycaster._find_interactable_ancestor()` walks UP from the
## hit collider looking for an `Interactable` ancestor. If `Pickup` were
## a child of the RigidBody3D, the walk-up would never see it. Wrapping
## the body in a Pickup parent puts it on the walk-up path.
##
## ## Why all visual children get reparented under the body (MF4 restructure)
##
## When `CarryController.grab()` reparents `Pickup` to the camera Marker3D
## (I.3), the entire visual + physics subtree must follow. If a `Mesh` were
## still a sibling of `Pickup` under `instance`, it would stay at the
## original cell position while the body flew up to the player's hands —
## phantom prop bug. The factory walks `instance.get_children()` (shallow,
## direct children only) and reparents every Node3D-descended visual node
## under the new RigidBody3D. Deeper subtrees ride along automatically
## because they're descendants of those direct children.
##
## **Transform preservation:** the chain
## `instance.world_xf * mesh.local_xf` becomes
## `instance.world_xf * Pickup.identity * RB.identity * mesh.local_xf`,
## algebraically identical. Direct-child local transforms are NOT touched.
## We use `add_child` to RB after `remove_child` from `instance`, NOT
## `reparent(keep_global_transform=true)`, because the wrapper chain is
## identity by construction.
##
## **AnimationPlayer caveat:** AnimationPlayer tracks reference targets
## by NodePath. Reparenting breaks those paths. Carryable MW records
## (WEAP / ARMO / CLOT / BOOK / ALCH / INGR / MISC / APPA / LOCK / PROB /
## REPA / LIGH-with-FLAG_CAN_CARRY) never carry NIF AnimationPlayers in
## practice — those live on flags / banners / rotating room props which
## are STAT or moveable_static, not the 12 carryable types. The factory
## skips AnimationPlayer with a `push_warning` if it ever encounters one.
##
## `pickup_interactable_script` is a Script object the caller passes in
## (the adapter's PickupInteractable subclass). Kept as a parameter so
## this framework file has zero knowledge of any specific subclass.
## The script must extend `Interactable` and expose `record_id`,
## `display_name`, and `mass_kg` as set-able properties.
static func convert_static_to_rigid(
	instance: Node3D,
	mass_kg: float,
	record_id: StringName,
	display_name: String,
	pickup_interactable_script: Script,
) -> RigidBody3D:
	if instance == null:
		return null
	if pickup_interactable_script == null:
		# Without a Pickup wrapper the raycaster can't find an Interactable.
		# Caller error — refuse to convert silently and broken.
		push_error("CarryableBodyFactory: pickup_interactable_script is required")
		return null

	var static_body: StaticBody3D = _find_first_static_body(instance)
	if static_body == null:
		# No baked collision from NIF. MW item models (weapons, potions,
		# books) are often purely visual — the original game used click-
		# raycast, not physics. Generate a BoxShape3D from the mesh AABB
		# so the item can become a carryable RigidBody3D.
		static_body = _generate_static_body_from_aabb(instance)
		if static_body == null:
			# No meshes either — can't generate collision. Stay static.
			return null

	var clamped_mass: float = clampf(mass_kg, MASS_MIN_KG, MASS_MAX_KG)

	# I.5 — substitute BuoyancyBody3D when the ocean system is live.
	# BuoyancyBody3D extends RigidBody3D so the rest of the convert
	# path is unchanged. The frozen-body early-out guard inside
	# BuoyancyBody3D._physics_process keeps perf cost ~zero on inland
	# clutter that never sees water. Probes get added below after the
	# collision shapes are reparented (we need shape AABBs to size them).
	var rb: RigidBody3D
	if _ocean_active():
		rb = BuoyancyBody3DScript.new()
	else:
		rb = RigidBody3D.new()
	rb.name = static_body.name  # preserve "CollisionBody" / similar
	# Identity transform — the wrapper Pickup sits at the same position
	# the StaticBody3D used to occupy (almost always identity in NIF
	# prototypes; whatever it was, the wrapper inherits it below).
	rb.collision_layer = SPAWN_LAYER
	rb.collision_mask = SPAWN_MASK
	rb.mass = clamped_mass
	rb.freeze = true
	rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	rb.contact_monitor = false
	rb.can_sleep = true
	rb.gravity_scale = 1.0
	rb.continuous_cd = true

	# Diagnostic metadata so the console picker and gameplay code can
	# read carryable info without walking siblings.
	rb.set_meta("carryable", true)
	rb.set_meta("record_id", String(record_id))
	rb.set_meta("display_name", display_name)
	rb.set_meta("mass_kg", clamped_mass)

	# Reparent the CollisionShape3D children. Resources are shared by
	# reference; the BoxShape3D / ConvexPolygonShape3D / etc. don't need
	# duplication.
	#
	# Clear `owner` before reparent: `duplicate()` copies owner chains from
	# the prototype, so children here carry `owner == prototype_root`. When
	# we re-add them under `rb` (whose ancestor chain does NOT include the
	# prototype root), Godot emits the "make owner inconsistent" warning
	# AND may corrupt internal state (RID errors, unimplemented-base-type
	# on the renderer side — see `docs/audit/MODEL_LOADER_RACE.md` §Post-
	# bridge sig 139). `owner` is only meaningful for editor-time scene
	# persistence; at runtime-spawn it must be null.
	var children := static_body.get_children()
	for child in children:
		_clear_owner_recursive(child)
		static_body.remove_child(child)
		rb.add_child(child)

	# I.5 — auto-generate buoyancy probes BEFORE the body enters the
	# scene tree. `BuoyancyBody3D._ready()` caches `_probes` once via
	# `_find_probes()`. If we add probes after `add_child` (and therefore
	# after `_ready` fires), the cache will be empty and the body will
	# never sample wave height. Order matters: shapes first (so the AABB
	# walk has something to compose from), THEN probes, THEN add to tree.
	if rb is BuoyancyBody3D:
		_add_aabb_probes(rb)

	# Build the Pickup wrapper. It inherits the old StaticBody3D's
	# transform so the rigid body ends up exactly where the static body
	# was (which, after `_apply_transform(instance, ref, true)`, is the
	# correct world position once `instance` is added to the cell).
	var pickup: Node3D = pickup_interactable_script.new()
	pickup.name = "Pickup"
	pickup.transform = static_body.transform
	pickup.set("record_id", String(record_id))
	pickup.set("display_name", display_name)
	pickup.set("mass_kg", clamped_mass)
	pickup.add_child(rb)

	# Swap into the parent at the same index so visual order is stable.
	var parent := static_body.get_parent()
	var idx := static_body.get_index()
	parent.remove_child(static_body)
	static_body.queue_free()
	parent.add_child(pickup)
	parent.move_child(pickup, idx)

	# MF4 mesh-follow restructure (I.3): pull every other direct child of
	# `parent` (the prop root) under the new RigidBody3D so the entire
	# visual subtree follows the body when CarryController.grab()
	# reparents Pickup to the camera Marker3D. AnimationPlayer is the only
	# node type with NodePath bindings that would break — skip with warn.
	var movable: Array[Node] = []
	for child in parent.get_children():
		if child == pickup:
			continue
		if child is AnimationPlayer:
			push_warning("CarryableBodyFactory: AnimationPlayer on carryable prop — NodePath bindings will not survive grab. Skipping reparent for: %s" % child.name)
			continue
		movable.append(child)
	for child in movable:
		_clear_owner_recursive(child)
		parent.remove_child(child)
		rb.add_child(child)

	# Tag the prop root so callers can assert before freeing the parent.
	# `PickupInteractable.interact()` frees `get_parent()` on a successful
	# pickup; this meta lets future call sites (and reviewer scans) confirm
	# that the parent really is a carryable wrapper before destroying it.
	# Set on the *parent* (the NIFRoot / prop root) — that's what gets freed.
	if parent != null:
		parent.set_meta("carryable_wrapper", true)

	return rb


## Clear `owner` on `node` and every descendant. Called before a reparent
## hop so Godot doesn't emit "owner inconsistent" warnings and, more
## importantly, doesn't leave a dangling owner pointer into the old tree.
##
## Rationale: `duplicate()` on a scene prototype copies the owner chain
## onto the duplicated subtree (each inner node's `owner` points at the
## duplicated root). When we reparent one of those inner nodes out from
## under the duplicated root and into a freshly-constructed RigidBody3D,
## the node's `owner` no longer lies on its new ancestor chain — Godot
## treats that as a latent corruption and has been observed to emit RID
## errors (`wrong RID`, `occluder null`, `unimplemented base type`) and
## eventually segfault on the renderer side. See `docs/audit/
## MODEL_LOADER_RACE.md` §Post-bridge sig 139.
##
## `owner` is an editor-persistence concept; at runtime-spawn it must be
## null. Walks the full subtree because any descendant's owner can be the
## source of the dangling reference.
static func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)


## Recursively find the first StaticBody3D inside `node`.
## Most NIF prototypes carry exactly one body at depth 1 (sibling of
## MeshInstance3D nodes), but a few have nested groups — recurse to be safe.
static func _find_first_static_body(node: Node) -> StaticBody3D:
	if node is StaticBody3D:
		return node as StaticBody3D
	for child in node.get_children():
		var found := _find_first_static_body(child)
		if found != null:
			return found
	return null


## Generate a StaticBody3D + BoxShape3D from the combined mesh AABB of
## `instance`. Used as fallback when the NIF model has no baked collision
## shapes. Returns null if no meshes found. The generated body uses
## collision layers matching the standard spawn config so the subsequent
## rigid body conversion path proceeds normally.
static func _generate_static_body_from_aabb(instance: Node3D) -> StaticBody3D:
	var aabb := _compute_item_aabb(instance)
	if not aabb.has_volume():
		return null
	var body := StaticBody3D.new()
	body.name = "GeneratedCollision"
	body.collision_layer = LAYER_ENVIRONMENT
	body.collision_mask = LAYER_ENVIRONMENT
	var shape := CollisionShape3D.new()
	shape.name = "AABBShape"
	var box := BoxShape3D.new()
	box.size = aabb.size
	shape.shape = box
	shape.position = aabb.get_center()
	body.add_child(shape)
	instance.add_child(body)
	return body


## Compute combined local-space AABB from all MeshInstance3D descendants.
## Uses local transforms only — safe before the node enters the tree.
static func _compute_item_aabb(root: Node3D) -> AABB:
	var aabbs: Array[AABB] = []
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		aabbs.append((root as MeshInstance3D).mesh.get_aabb())
	for child in root.get_children():
		_collect_item_aabbs(child, Transform3D.IDENTITY, aabbs)
	if aabbs.is_empty():
		return AABB()
	var combined: AABB = aabbs[0]
	for i in range(1, aabbs.size()):
		combined = combined.merge(aabbs[i])
	return combined


static func _collect_item_aabbs(node: Node, parent_xf: Transform3D, out: Array[AABB]) -> void:
	var xf: Transform3D = parent_xf
	if node is Node3D:
		xf = parent_xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			out.append(xf * mi.mesh.get_aabb())
	for child in node.get_children():
		_collect_item_aabbs(child, xf, out)


## I.5 — is the ocean system live? Used to decide whether spawned
## carryables should be `BuoyancyBody3D` (floats) or plain `RigidBody3D`
## (sinks like a brick — fine for inland-only worlds). Reads through
## the autoload `OceanManager` global. Safe even if the autoload's
## `_system_initialized` is false (returns false in that case).
static func _ocean_active() -> bool:
	# Autoload is registered in project.godot. If the project ever
	# removes it, this static parse-time reference will fail and
	# the spawn path needs a manual `if Engine.has_singleton(...)` guard.
	if OceanManager == null:
		return false
	return OceanManager.is_initialized()


## I.5 — auto-generate buoyancy probes from the body's collision AABB.
## 4 bottom corners + 1 center bottom = 5 probes total. No per-item
## authoring required. Per spec §6.4.
##
## AABB is computed in the body's local space by walking every
## `CollisionShape3D` child, getting each shape's debug-mesh AABB
## (works for any `Shape3D` subclass), and composing all of them via
## the shape's local transform.
static func _add_aabb_probes(body: BuoyancyBody3D) -> void:
	var aabb: AABB = _compute_collision_aabb(body)
	if aabb.size == Vector3.ZERO:
		# No collision shapes (or zero-volume) — can't size probes.
		# Skip; the body will sink. Caller can add probes manually.
		push_warning("CarryableBodyFactory: no collision AABB for buoyancy probes on '%s'" % body.name)
		return

	var bottom_y: float = aabb.position.y
	var center: Vector3 = aabb.get_center()
	var probe_positions: Array[Vector3] = [
		Vector3(aabb.position.x, bottom_y, aabb.position.z),
		Vector3(aabb.end.x,      bottom_y, aabb.position.z),
		Vector3(aabb.position.x, bottom_y, aabb.end.z),
		Vector3(aabb.end.x,      bottom_y, aabb.end.z),
		Vector3(center.x,        bottom_y, center.z),
	]
	for pos: Vector3 in probe_positions:
		var probe: Node3D = BuoyancyProbe3DScript.new()
		probe.position = pos
		body.add_child(probe)


## Compose the local AABB of every `CollisionShape3D` child of `body`
## into a single AABB in `body`'s local space. Each shape's AABB is
## obtained via `Shape3D.get_debug_mesh().get_aabb()` which works for
## any shape type (Box, Sphere, Capsule, ConvexPolygon, ConcavePolygon,
## CylinderShape, etc.) without needing per-type branching.
static func _compute_collision_aabb(body: RigidBody3D) -> AABB:
	var combined: AABB = AABB()
	var first: bool = true
	for child in body.get_children():
		if not (child is CollisionShape3D):
			continue
		var cs: CollisionShape3D = child
		if cs.shape == null:
			continue
		var debug_mesh: ArrayMesh = cs.shape.get_debug_mesh()
		if debug_mesh == null:
			continue
		var shape_aabb: AABB = debug_mesh.get_aabb()
		# Transform the shape-local AABB into body-local space using
		# the CollisionShape3D's transform.
		var local_aabb: AABB = cs.transform * shape_aabb
		if first:
			combined = local_aabb
			first = false
		else:
			combined = combined.merge(local_aabb)
	return combined
