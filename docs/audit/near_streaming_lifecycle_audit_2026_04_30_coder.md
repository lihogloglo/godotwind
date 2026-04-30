# NEAR Streaming Lifecycle Audit

Date: 2026-04-30  
Owner: coder  
Scope: P0.4 first pass, focused on scene-tree child attach / unload lifecycle

## Current Verdict

The static descriptor slice moves the old `SceneState` material-RID crash site
out of the observed failure path. The current blocker is scene-tree publication:
a stationary `--quit-after-ready=20` probe crashed natively after a
`981.3ms` instantiation overrun dominated by `addc=976.4ms`, with the last
breadcrumb at:

```text
cm::inst_tail_done :: queue=54 child=0 cfin=0
```

This means the child attach queue drained to zero and the crash happened after
or during native processing triggered by a very expensive `add_child()` publish.
The time budget did not protect the frame because one scene-tree attach is not
preemptible.

## Canonical Pattern

Godot's documented threading model keeps scene-tree mutation on the main
thread. The production pattern is:

- worker/threaded lanes prepare resources and pure data only
- main-thread publish is explicit and budgeted
- each publish record has one owner
- unload either cancels unowned detached records or pauses payload-owned
  records through a state-reversal window
- static clutter stays server-direct; only sparse interactive/gameplay objects
  enter the scene tree

For heavy refs, a count-limited `add_child()` queue is not enough. If one
attached subtree contains hundreds of nodes, the proper fix is to avoid
publishing that subtree as a `Node3D` in NEAR unless it is truly interactive.

## Ownership Map

| Object | Current Owner | Release Point | Risk |
|--------|---------------|---------------|------|
| `AsyncCellRequest` | `CellManager._async_requests` | `get_async_result()`, `cancel_async_request()`, `finalize_unloaded_cell()` | split state with `NativeStreamingManager._async_requests` grid map |
| `CellPayload` | `AsyncCellRequest.payload` | request erase / finalization | correct direction, but owns only static-prepare slice so far |
| loaded `cell_node` | `NativeStreamingManager._loaded_cells` after `get_async_result()` | `_process_budgeted_unloading()` | state-reversal limbo means it can be hidden but still valid |
| unloading `cell_node` | `NativeStreamingManager._unloading_cells` | `_process_budgeted_unloading()` | request remains parked in `_unloading_request_ids` |
| detached child `Node3D` | `CellManager._pending_child_attaches` | `_drain_pending_child_attaches()`, request discard, fast cleanup | global queue crosses cell lifetime boundaries |
| child attach record | `CellManager._pending_child_attaches` | popped in drain or filtered by request | not payload-owned; previous payload move crashed visibly |
| scene-tree child after attach | `cell_node` subtree | cell unload child `queue_free()` | one `add_child()` can spike/crash natively |
| `StreamedResourceHandle` | `CellPayload`, then bound to `cell_node` meta | node free / owner release | accepted P0.2 path |
| static prepare record | `CellPayload` plus `CellManager` selector | pop/requeue/discard | accepted first P0.3 slice |
| static RS instance | `StaticObjectRenderer` | `remove_cell_instances()` / clear | owner is clear, but still needs full RID audit later |
| collision worker/result | `AsyncCellRequest` | drain/cancel/finalize | mostly explicit, but publish/free still needs full RID audit |

## Child Attach Lifecycle

Current flow:

1. `process_async_instantiation()` creates a detached `Node3D`.
2. `_queue_child_attach(request_id, request.cell_node, obj)` stores it in the
   global `_pending_child_attaches` queue.
3. `_drain_pending_child_attaches()` pops at most one record per drain call and
   calls `parent.add_child(child)` if the request/cell is still active.
4. `_unload_cell()` pauses request publish and hides the cell node, but keeps
   the request and queues alive for possible state reversal.
5. `finalize_unloaded_cell()` discards leftover attach records only after the
   unload limbo closes.

The guard logic prevents obvious use-after-free cases. The remaining problem is
not primarily a missing `is_instance_valid()` check. The observed spike shows a
single valid attach can be too large and can trigger native instability.

## Failed Prior Approach

Moving `_pending_child_attaches` into `CellPayload` without changing the
publication semantics passed automated smoke but crashed visibly around unload.
That proves queue ownership alone is not enough. The next attempt must include
an owner/free-point proof for detached nodes and must address the size of what
is being attached.

## Required Next Slice

Before retrying payload-owned child attach:

1. Add per-attach diagnostics for slow `add_child()` calls:
   request id, grid, type, model path, ref id, child root class, child count,
   descendant count, and elapsed ms.
2. Use the diagnostics to identify which ref type is creating the 900ms attach.
3. For heavy static-looking refs, route visuals through `StaticObjectRenderer`
   and attach only a lightweight interaction/collision root if needed.
4. Only after heavy subtree publication is reduced, move child attach records
   into `CellPayload`.

Acceptance for the diagnostics slice:

- Stationary `--quit-after-ready=20` either reaches `READY_QUIT` or logs the
  exact child attach that causes the native crash/spike.
- Dense-loop stress still completes.
- No new defer-frame constants or permanent disable flags.

## Diagnostics Slice Result

Implemented in `src/core/world/cell_manager.gd`:

- `_queue_child_attach()` records source metadata with each detached child:
  request id, grid, type, model path, item id, ref id, and ref num.
- `_drain_pending_child_attaches()` brackets each `add_child()` with
  `cm::attach_one_begin` / `cm::attach_one_done` breadcrumbs.
- attaches over 16ms log `[child-attach-spike]` with direct child and
  descendant counts.

Verification after instrumentation:

- Stationary hidden `--quit-after-ready=20` reached `READY_QUIT`, drained queue
  and child attach counts to zero, then hit the known post-quit native signal
  11. No individual child attach crossed the 16ms slow log threshold.
- Dense-loop stress `child_attach_diag_dense_2026_04_30_coder` completed and
  wrote benchmark artifacts, then hung after `BENCH_QUIT` in the known
  null-material/native finalization loop until killed by the watchdog.
- No script parse errors or invalid calls were observed.

Interpretation:

The earlier 976ms `addc` stationary spike did not reproduce with diagnostics
enabled. Child attach remains architecturally split across a global queue, but
there is not yet a named heavy child to rewrite. The immediate repeatable
failure is still automated shutdown/finalization, while traversal completed.

## Open Risks

- `CellManager` and `NativeStreamingManager` both keep request state maps. This
  is the broader P0.3 split-brain the payload scheduler must remove.
- `add_child()` cost is currently counted after the fact. The budget can limit
  how many records are attempted, but not the cost of one record.
- Automated hidden quit still has a known post-teardown native signal 11; keep
  it tracked separately from the child-attach startup crash signature.
