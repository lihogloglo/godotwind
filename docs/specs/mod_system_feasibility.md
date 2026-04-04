# Mod System Feasibility Study

**Date:** 2026-04-04
**Status:** Draft / Under Review

---

## 1. Goal

Allow mods to work on Godotwind the same way they work with OpenMW: load order-based file overrides, ESP/ESM plugin merging, texture/mesh replacement via loose files or archives. The system must be **framework-generic** (any game data source), with Morrowind as a **translation-layer special case**.

---

## 2. What OpenMW Does (Reference Model)

OpenMW's mod system is built on three layers:

### Layer 1: Virtual Filesystem (VFS)
- A unified file index (`FileMap`) backed by multiple archive sources
- Two archive types: `FileSystemArchive` (loose files) and `BsaArchive` (BSA/BA2)
- **Last registered archive wins** — archives added later overwrite earlier entries in the index
- Loading order: vanilla BSAs first, then mod BSAs, then loose file directories
- After `buildIndex()`, the VFS is **read-only and thread-safe**
- All resource access goes through VFS — textures, meshes, sounds, everything

### Layer 2: Resource System
- Wraps VFS with typed managers: `ImageManager`, `SceneManager`, `NifFileManager`
- Caches loaded resources; cache can be invalidated
- Texture replacement is **purely VFS-based** — no special handling, just file path override

### Layer 3: Record Store (ESM/ESP Merging)
- `ESMStore` contains typed dictionaries (`Store<T>`) for each record type
- Plugins loaded in order; **last-loaded record wins** on ID conflicts
- No fancy merge — simple map-based replacement
- Master file dependencies validated at load time
- Runtime changes (save-game) stored in separate `mDynamic` overlay

### Key Insight
OpenMW's mod system is simple by design. There's no "mod API" — mods work by:
1. Placing files at vanilla paths in a data directory (VFS override)
2. Providing ESP/ESM plugins that redefine records (last-wins)

---

## 3. What Godotwind Already Has

We already have significant mod infrastructure:

### ModRegistry (`src/core/modding/mod_registry.gd`)
- Manifest-based (`user://mods.json`) with load order
- Scans mod folders for ESPs, BSAs, prebaked assets, loose files
- Flattened `_asset_map` for O(1) path resolution (later mods override earlier)
- Wired into `world_explorer.gd` startup

### Asset Pipeline Integration
- **TextureLoader** checks `_mod_registry` first (Priority 1) before BSA fallback
- **ModelLoader** checks `_mod_registry` for mod-specific prebaked `.res` files
- **BSAManager** loads mod BSAs after vanilla (via `mod_registry.get_bsa_load_order()`)
- **ESMManager** loads mod ESPs after vanilla (via `mod_registry.get_esp_load_order()`)

### What Works Today
| Feature | Status |
|---------|--------|
| Mod manifest (mods.json) | Working |
| Mod folder scanning (ESP, BSA, loose, prebaked) | Working |
| Mod BSA loading in order | Working |
| Mod ESP loading in order | Working |
| Texture override (loose files) | Working |
| Model override (prebaked .res) | Working |
| Load order priority (last wins) | Working |

---

## 4. What's Missing

### 4.1 Virtual Filesystem Layer (HIGH priority)

**Problem:** We don't have a unified VFS. ModRegistry, BSAManager, and TextureLoader each do their own path resolution with slightly different logic. OpenMW routes ALL file access through one VFS.

**What we need:** A `VirtualFileSystem` class that:
- Registers sources in priority order: vanilla BSAs, mod BSAs, mod loose files
- Provides a single `resolve(path) -> DataSource` API
- Normalizes all paths once (lowercase, backslash)
- Is thread-safe after initialization (read-only index)
- Replaces the scattered resolution logic in TextureLoader, ModelLoader, BSAManager

**Complexity:** Medium. The pieces exist — this is about unification, not new functionality.

**Framework design:** The VFS itself is generic. Archive format support (BSA, ZIP, PCK) lives in adapter classes. Morrowind's BSA adapter already exists.

### 4.2 ESM/ESP Record Merging (MEDIUM priority)

**Problem:** ESMManager currently loads multiple files, but record conflict resolution is implicit (Dictionary insert = last wins). There's no:
- Dependency validation (master file checks)
- Load order enforcement beyond array ordering
- Awareness of which mod provided which record (for debugging)

**What we need:**
- Record provenance tracking: `record.source_file` or a parallel map
- Master file dependency checking (ESP declares its masters)
- Warning on overridden records (for mod conflict debugging)
- A "mod conflict report" that lists which records are overridden by which mod

**Complexity:** Low-Medium. The last-wins behavior already works. This is about visibility and safety.

**Framework design:** Record merging is generic (Dictionary overlay). The ESM/ESP format parsing is Morrowind-specific (already in `src/core/esm/`).

### 4.3 Texture Replacement Pipeline (MEDIUM priority)

**Problem:** TextureLoader supports mod loose files, but:
- No mod BSA texture resolution (only loose files checked via ModRegistry)
- No cache invalidation when mods change
- No prebaked texture override (only prebaked models, not standalone textures)
- DDS loading from mod BSAs untested at scale

**What we need:**
- VFS-based texture resolution (solves loose + BSA in one path)
- Cache-aware reloading (if mod list changes, invalidate affected textures)
- Prebaked texture support (mod provides optimized `.ctex` or `.res` overrides)

**Complexity:** Low if VFS is built first (texture resolution becomes a VFS query).

### 4.4 Mod Prebaking Pipeline (LOW priority, HIGH impact)

**Problem:** Godotwind's performance relies on prebaked `.res` files (1-5ms load vs 50-200ms NIF parse). Mods that add new meshes need their own prebaking pass.

**What we need:**
- `prebake_mod(mod_path)` command that:
  1. Scans mod ESP for new/modified records referencing meshes
  2. Converts mod NIFs to `.res` in `mod_path/prebaked/`
  3. Generates impostors for new statics (FAR tier)
  4. Generates terrain patches if mod has landscape changes
- Integration with existing prebaking tools (`src/tools/prebaking/`)
- Incremental rebake (only changed assets)

**Complexity:** Medium-High. The prebaking pipeline exists but isn't modular enough for per-mod runs.

### 4.5 Mod Manager UI (LOW priority)

**Problem:** Currently mods.json must be hand-edited.

**What we need:**
- In-game or editor panel to:
  - Add/remove mod folders
  - Reorder load priority (drag-and-drop)
  - Enable/disable individual mods
  - Show conflict report
  - Trigger prebaking for new mods

**Complexity:** Medium. UI work, no architectural risk.

### 4.6 Non-Morrowind Mod Formats (FUTURE)

**Problem:** The framework should support mods for any game, not just Morrowind ESPs.

**What we need (eventually):**
- Pluggable record format adapters (ESP is one; JSON/YAML/custom could be others)
- Generic "mod plugin" interface: `load_records()`, `get_overrides()`, `get_dependencies()`
- The VFS already handles this (it's format-agnostic for file overrides)

**Complexity:** Low for the interface, varies per adapter.

---

## 5. Existing Godot Mod Frameworks — Should We Use One?

### Godot Mod Loader (GodotModding)
- Most mature (7 shipped games: Brotato, Dome Keeper, etc.)
- PCK/ZIP-based distribution, script hooking via preprocessor
- **Not a good fit:** Designed for Godot-native games (PCK resource packs, GDScript mods). We need raw file override (textures, meshes, BSAs) and record-level merging. Our pipeline is data-driven, not scene/script-driven.

### Godot Sandbox (libriscv)
- RISC-V sandboxing for safe mod execution (C++/Rust/SafeGDScript)
- **Potentially useful later** if we support scripted mods, but overkill for data mods.

### Verdict
**Build our own**, mirroring OpenMW's architecture. Our needs (VFS, BSA archives, ESM records, prebaked caches) are too domain-specific for generic Godot mod loaders. The good news: we're 60% there already.

---

## 6. Architecture Proposal

```
┌─────────────────────────────────────────────┐
│              Mod Manager UI                  │  (future)
│         (load order, enable/disable)         │
└─────────────┬───────────────────────────────┘
              │ writes mods.json
              v
┌─────────────────────────────────────────────┐
│            ModRegistry                       │  (exists)
│     manifest, mod scanning, load order       │
└─────────────┬───────────────────────────────┘
              │ registers sources
              v
┌─────────────────────────────────────────────┐
│        VirtualFileSystem (NEW)               │  <-- the missing piece
│                                              │
│  Sources (in priority order):                │
│    1. Mod N loose files (highest)            │
│    2. Mod N BSAs                             │
│    3. ...                                    │
│    4. Mod 1 loose files                      │
│    5. Mod 1 BSAs                             │
│    6. Vanilla BSAs (lowest)                  │
│                                              │
│  API: resolve(path) -> bytes                 │
│       has(path) -> bool                      │
│       list(pattern) -> paths                 │
│                                              │
│  Thread-safe after build_index()             │
└──────┬──────────┬──────────┬────────────────┘
       │          │          │
       v          v          v
  TextureLoader  ModelLoader  ESMManager
  (uses VFS)     (uses VFS)   (record merging)
                    │
                    v
        ┌───────────────────────┐
        │  On-Demand Converter  │
        │  (WorkerThreadPool)   │
        │                       │
        │  Cache miss:          │
        │   VFS → raw NIF bytes │
        │   → C# NIF converter  │
        │   → save .res to      │
        │     mod_cache/{id}/   │
        │   → return model      │
        │                       │
        │  Cache hit:           │
        │   mod_cache → .res    │
        │   → 1-5ms load        │
        └───────────────────────┘
```

### Framework vs Morrowind Split

| Layer | Framework (generic) | Morrowind (adapter) |
|-------|-------------------|-------------------|
| VFS | `VirtualFileSystem` — source registration, path resolution, index building | `BsaArchive` — BSA format reader |
| Records | `RecordStore` — typed dictionaries, last-wins merge, provenance | `ESMParser` — ESM/ESP binary format |
| Assets | `TextureLoader`, `ModelLoader` — VFS-backed, cached | `NifConverter`, `DdsLoader` — format-specific |
| On-Demand Convert | `AsyncConverter` — cache-miss → WorkerThreadPool → save .res | `NifConverter` — NIF→Godot mesh |
| Mods | `ModRegistry` — manifest, scanning, load order | `EspScanner` — ESP dependency/master validation |

---

## 7. Implementation Phases

### Phase 1: VFS Unification (1-2 sessions)
- Create `VirtualFileSystem` class (RefCounted, like ModRegistry)
- Adapter interface: `VFSArchive` with `list_files()` and `read_file()`
- Wrap existing `BSAManager` as a `VFSArchive`
- Wrap loose file directories as `VFSArchive`
- Wire into ModRegistry: `build_vfs()` returns configured VFS
- Update TextureLoader to use VFS instead of direct BSA + ModRegistry checks
- Update ModelLoader similarly

### Phase 2: Record Provenance & Conflict Detection (1 session)
- Add `source_file: String` to ESM records (or parallel Dictionary)
- Log warnings when a mod record overrides vanilla
- Add `get_conflict_report() -> Array[Dictionary]` to ESMManager
- Master file dependency checking for ESPs

### Phase 3: On-Demand Conversion + Optional Prebake (2-3 sessions)

**Key insight:** The prebake pipeline IS the mod loading pipeline — just lazy instead of eager.

Currently `ModelLoader.runtime_mode = true` returns null for uncached models. Instead:
- On cache miss, **queue async NIF→.res conversion** via WorkerThreadPool
- Save converted .res to `mod_cache/{mod_id}/meshes/...`
- Return the model when conversion completes (placeholder/skip until ready)
- On cache hit, load .res directly (1-5ms, identical to vanilla)

Implementation:
- Add `mod_cache/` directory under cache base (per-mod subdirectories)
- ModelLoader cache-miss path: check VFS → NIF found → async convert → save .res → callback
- Cache keyed by NIF file hash — mod updates auto-invalidate stale .res
- Frame-budgeted: conversions run on WorkerThreadPool, same pattern as streaming pipeline
- Optional `prebake_mod <mod_name>` console command for power users (bulk-converts all mod NIFs ahead of time)
- Impostor generation for new FAR-tier statics (async, same as vanilla)

**Why not tes3/Rust bindings:** Evaluated https://github.com/Greatness7/tes3 — solid Rust NIF parser (127 block types, SIMD), but no Godot bindings exist. Would require writing a gdext wrapper + full NIF→ArrayMesh conversion layer + maintaining a third native language (C# + Rust). Our existing C# NIF pipeline already works at 20-50x GDScript speed. Not worth the integration cost.

### Phase 4: Mod Manager UI (1-2 sessions)
- Panel in world_explorer or standalone scene
- Mod list with drag-to-reorder, enable/disable checkboxes
- Conflict report display
- "Prebake All" button per mod (optional optimization)
- Saves to mods.json

### Phase 5: Testing & Polish (1 session)
- Test with real Morrowind mods (Tamriel Rebuilt, texture packs)
- Performance profiling with 10+ mods loaded
- Measure first-load penalty (on-demand conversion) vs subsequent loads
- Edge cases: missing masters, circular deps, corrupted BSAs, mod updates

---

## 8. Feasibility Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| **Technical feasibility** | HIGH | 60% infrastructure exists. VFS is the main new piece. |
| **Architectural fit** | HIGH | Follows existing patterns (RefCounted managers, framework/adapter split) |
| **Effort** | MEDIUM | ~6-9 sessions total across all phases |
| **Risk** | LOW | No architectural rewrites needed. Incremental additions to working code. |
| **Performance impact** | LOW | VFS adds one dictionary lookup. Prebaked cache keeps load times fast. |
| **OpenMW compatibility** | HIGH | Same mod structure works: data dirs with loose files + ESPs + BSAs |
| **Framework generality** | HIGH | VFS + ModRegistry are game-agnostic. Only BSA/ESM adapters are MW-specific. |

### Bottom Line

**Highly feasible.** The hardest part (asset pipeline, BSA reading, ESM parsing, prebaking, ModRegistry) already exists. The main missing piece is a unified VFS to replace scattered resolution logic. The existing ModRegistry + TextureLoader + ModelLoader integration proves the pattern works — we just need to formalize it.

Real Morrowind mods (texture replacers, Tamriel Rebuilt, etc.) should work with Phases 1-2 complete. New-content mods (new meshes/NPCs) work immediately with Phase 3 (on-demand conversion) — first load is slower (50-200ms per NIF, async), subsequent loads are instant (1-5ms cached .res). Same UX as OpenMW (install mod → play) with better long-term performance.

---

## 9. Comparison: OpenMW vs Godotwind (Current vs Target)

| Feature | OpenMW | Godotwind (now) | Godotwind (target) |
|---------|--------|-----------------|-------------------|
| VFS with priority layering | Yes (C++) | Partial (scattered) | Yes (Phase 1) |
| BSA archive loading | Yes | Yes (BSAManager) | Yes (as VFS adapter) |
| Loose file override | Yes | Yes (TextureLoader) | Yes (via VFS) |
| ESP/ESM load order | Yes | Yes (ESMManager) | Yes (unchanged) |
| Record last-wins merge | Yes | Yes (implicit) | Yes + provenance (Phase 2) |
| Master file validation | Yes | No | Yes (Phase 2) |
| Texture replacement | Yes (VFS) | Yes (loose only) | Yes (VFS, loose+BSA) |
| Mesh replacement | Yes (VFS) | Partial (prebaked) | Yes (VFS + prebake, Phase 3) |
| Mod manager UI | Yes (launcher) | No | Yes (Phase 4) |
| Thread-safe file access | Yes (post-init) | Yes (BSA mutex) | Yes (VFS post-build) |
| Prebaked asset cache | N/A (runtime) | Yes (.res files) | Yes + per-mod cache (Phase 3) |

---

## 10. Open Questions

1. **Should VFS replace BSAManager entirely, or wrap it?** Wrapping is safer and preserves BSAManager's LRU cache. VFS delegates to BSAManager for BSA reads.

2. **How to handle mod BSA + mod loose file priority?** OpenMW loads loose files AFTER BSAs (loose wins). We should match this: `mod_loose > mod_bsa > vanilla_bsa`.

3. **Do we support Godot PCK mods too?** For non-Morrowind use cases, PCK is Godot's native format. The VFS could have a `PckArchive` adapter alongside `BsaArchive` and `FileSystemArchive`. Low priority but worth the interface slot.

4. **Cache invalidation when mods change?** When the user changes mod list, all affected caches (texture, model, ESM) need invalidation. Simplest approach: hash the mod list, invalidate everything if hash changes.

5. **Mod-provided shaders?** Not in scope for Phase 1-5, but the VFS pattern extends to shader files naturally.
