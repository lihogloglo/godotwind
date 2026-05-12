$ErrorActionPreference = "Stop"

$Repo = "davurphy/godotwind"
$Gh = "C:\Program Files\GitHub CLI\gh.exe"
$TempDir = Join-Path $env:TEMP "godotwind-log-issues"
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

function New-IssueBody {
	param(
		[string]$Name,
		[string]$Body
	)
	$Path = Join-Path $TempDir $Name
	Set-Content -LiteralPath $Path -Value $Body -Encoding UTF8
	return $Path
}

$Issues = @(
	@{
		Title = "Track shutdown-time RID and renderer resource leaks"
		Body = @"
## Source

Observed in `godot.log` copied from the main-scene smoke run on 2026-05-12.

## Actual log messages

```text
ERROR: 25 RID allocations of type 'P11GodotBody3D' were leaked at exit.
ERROR: 83 RID allocations of type 'P12GodotShape3D' were leaked at exit.
ERROR: Pages in use exist at exit in PagedAllocator: N33RendererSceneRenderImplementation22RenderForwardClustered32GeometryInstanceSurfaceDataCacheE
ERROR: Pages in use exist at exit in PagedAllocator: N33RendererSceneRenderImplementation22RenderForwardClustered32GeometryInstanceForwardClusteredE
ERROR: 4 shaders of type SceneForwardClusteredShaderRD were never freed
```

## Likely cause / first places to inspect

This looks like shutdown cleanup order or delayed resource release rather than a character-controller error. Likely suspects:

- streamed physics bodies/shapes still alive when the engine exits;
- native streaming manager or cell cleanup not draining all queued removals before quit;
- render resources/shader instances still referenced by active scene objects at shutdown.

## Notes

The character-controller Phase 5 smoke itself was clean: no controller/input/interaction errors were found.
"@
	},
	@{
		Title = "Investigate repeated CellStaticCollision missing .shapes.res sidecar warnings"
		Body = @"
## Source

Observed in `godot.log` copied from the main-scene smoke run on 2026-05-12.

## Actual log messages

There were 75 `CellStaticCollision` warnings. Examples:

```text
WARNING: CellStaticCollision: cell (-2, -9) - 237/237 prototypes had no shapes (Phase F miss or missing .shapes.res sidecar). Triangles dropped.
WARNING: CellStaticCollision: cell (-2, -8) - 175/175 prototypes had no shapes (Phase F miss or missing .shapes.res sidecar). Triangles dropped.
WARNING: CellStaticCollision: cell (-1, -9) - 142/142 prototypes had no shapes (Phase F miss or missing .shapes.res sidecar). Triangles dropped.
WARNING: CellStaticCollision: cell (-3, -9) - 98/98 prototypes had no shapes (Phase F miss or missing .shapes.res sidecar). Triangles dropped.
WARNING: CellStaticCollision: cell (0, -10) - 248/248 prototypes had no shapes (Phase F miss or missing .shapes.res sidecar). Triangles dropped.
```

## Likely cause / first places to inspect

The warning text points directly at Phase F static-collision shape sidecars. Likely causes:

- prebake/import did not generate `.shapes.res` sidecars for these prototypes;
- runtime lookup path does not match where sidecars are written;
- static-collision publication is running before the shape cache/sidecars are available;
- missing sidecars are expected for some objects, but the current warning is too noisy and hides real misses.

## Practical impact

Triangles are being dropped for static collision in affected cells, so this may reduce collision coverage or invalidate later physics/player traversal checks.
"@
	},
	@{
		Title = "Profile streaming frame overruns and instantiation spikes during main-scene smoke"
		Body = @"
## Source

Observed in `godot.log` copied from the main-scene smoke run on 2026-05-12.

## Actual log messages

```text
WARNING: [WARN] [streaming] [inst-spike 64.9ms] coll=0.0 class=3.0/124 mreq=0.0/2 disk=0.0 conv=0.0 prewarm=0.0 sprep=0.0/0 dispatch=0.0 cfin=0.0 loop=61.8 addc=0.0 static=0.0/0 light=0.0/0 actor=0.0/0 node=0.0/0 wstatic=0.0/0 wnode=0.0/0 defer=61.8/1 skip=0.0/0 other=0.0 ml=0.0 sreg=0.1 sadd=61.6 wp=0 instantiated=0 queue=26 burst=N
WARNING: [WARN] [streaming] [inst-spike 55.6ms] coll=0.0 class=0.0/0 mreq=0.0/1 disk=0.1 conv=0.0 prewarm=0.0 sprep=0.0/0 dispatch=0.0 cfin=0.0 loop=55.4 addc=0.0 static=0.0/0 light=0.0/0 actor=0.0/0 node=0.0/0 wstatic=0.0/0 wnode=0.0/0 defer=55.4/1 skip=0.0/0 other=0.0 ml=0.0 sreg=0.1 sadd=55.3 wp=0 instantiated=0 queue=4 burst=N
WARNING: [WARN] [streaming] Frame overrun: 17.1ms [cellupd:0.0 unload:0.0 async:0.0 inst:15.1 promo:0.0 coll:0.0 defer:0.0 queue:0.0 static:0.0 imp:0.0 hlod:0.0 light:1.9] (budget:8.0ms, overruns:5)
WARNING: [WARN] [streaming] Frame overrun: 15.0ms [cellupd:0.0 unload:0.0 async:0.0 inst:4.6 promo:0.0 coll:0.0 defer:0.0 queue:0.0 static:0.0 imp:8.5 hlod:0.0 light:1.9] (budget:8.0ms, overruns:6)
WARNING: [WARN] [streaming] Frame overrun: 12.6ms [cellupd:0.0 unload:0.0 async:0.0 inst:5.4 promo:0.0 coll:0.0 defer:0.0 queue:0.0 static:0.0 imp:5.4 hlod:0.0 light:1.7] (budget:8.0ms, overruns:17)
```

Autopsy examples:

```text
WARNING: [WARN] [autopsy] [autopsy 70.2ms stream_proc] top: instantiate=65.2, distant_light_manager=3.3, startup_tick=0.4, far_impostor_publish=0.0, async_complete=0.0, static_renderer_cull=0.0, cm_set_camera_position=0.0, unload=0.0 | sections_fired=8 unattributed=1.4ms
WARNING: [WARN] [autopsy] [autopsy 58.6ms stream_proc] top: instantiate=55.8, distant_light_manager=2.1, far_impostor_publish=0.0, async_complete=0.0, cell_preloader_update=0.0, cm_set_camera_position=0.0, static_renderer_cull=0.0, unload=0.0 | sections_fired=8 unattributed=0.7ms
```

## Likely cause / first places to inspect

The instrumentation points to main-thread streaming work, especially instantiate/deferred attach/static add paths and some impostor/light publication cost. Likely causes:

- deferred attachment work is not fully budgeted;
- instantiate/static-add work can still land in a single frame;
- FAR impostor publication and distant light manager work may need tighter frame budgets;
- startup/loading gates may allow too much work immediately after first playable.

## Acceptance direction

Keep the existing profiling instrumentation, but tune the streaming publication/instantiation budgets so spikes stay under the configured frame budget during normal traversal.
"@
	},
	@{
		Title = "Replace deprecated RenderingServer physics interpolation reset call"
		Body = @"
## Source

Observed in `godot.log` copied from the main-scene smoke run on 2026-05-12.

## Actual log message

```text
WARNING: instance_reset_physics_interpolation() is deprecated.
   at: _instance_reset_physics_interpolation_bind_compat_104269 (servers/rendering/rendering_server.compat.inc:58)
```

## Likely cause / first places to inspect

Some runtime path still calls the deprecated `RenderingServer.instance_reset_physics_interpolation()` compatibility binding. The recent character-controller hardening intentionally uses `Node3D.reset_physics_interpolation()` for player/fly/transition teleports, so this is probably an older rendering/streaming path rather than the new controller teleport work.

Search target:

```powershell
rg "instance_reset_physics_interpolation|reset_physics_interpolation" src
```

## Expected fix

Prefer the current Godot 4.6 node-level reset API where a visible node is moved discontinuously, or update the specific server-level call if it is genuinely needed by a RenderingServer-only instance path.
"@
	},
	@{
		Title = "Clean up startup asset/environment warnings in main-scene log"
		Body = @"
## Source

Observed in `godot.log` copied from the main-scene smoke run on 2026-05-12.

## Actual log messages

```text
WARNING: GENERAL - Message Id Number: 0 | Message Id Name: Loader Message
	windows_read_data_files_in_registry: Registry lookup failed to get layer manifest files.

WARNING: Terrain3D#9811:_notification:869: free_editor_textures requires `Assets` be saved to a file. Do so, or disable the former to turn off this warning

WARNING: Image format RGB8 not supported by hardware, converting to RGBA8.
```

## Likely cause / first places to inspect

- Vulkan/loader registry warning: likely machine/environment-specific graphics layer registry noise unless reproducible on other machines.
- Terrain3D warning: Terrain3D assets may not be saved to disk while `free_editor_textures` is enabled.
- RGB8 conversion: a texture import setting or source image format does not map directly to the current rendering backend/hardware format.

## Suggested handling

These do not look like character-controller failures. Track them as startup hygiene so the main log gets quieter and future smoke-pass regressions are easier to spot.
"@
	},
	@{
		Title = "Investigate gamepad mapping warnings for Switch controllers"
		Body = @"
## Source

Observed in `godot.log` copied from the main-scene smoke run on 2026-05-12.

## Actual log messages

The log reports four mapping warnings:

```text
Unrecognized output string "misc2" in mapping:
030000000d0f00000202000000000000,Horipad O Nintendo Switch 2 Controller,...

Unrecognized output string "misc2" in mapping:
030000007e0500006920000000000000,Nintendo Switch 2 Pro Controller,...
```

## Likely cause / first places to inspect

This looks like Godot/SDL controller database mapping metadata that Godot does not recognize (`misc2`) for some Switch controller entries. It may be upstream engine/input-db noise unless those controllers are actually used for Godotwind input validation.

## Suggested handling

Low priority unless gamepad support is being tested. If gamepad rebinding/input parity work resumes, verify whether these warnings affect action mapping; otherwise consider tracking upstream or filtering them from smoke-pass triage.
"@
	}
)

foreach ($Issue in $Issues) {
	$SafeName = ($Issue.Title.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-') + ".md"
	$BodyPath = New-IssueBody -Name $SafeName -Body $Issue.Body
	Write-Host "Creating: $($Issue.Title)"
	& $Gh issue create --repo $Repo --title $Issue.Title --body-file $BodyPath
}

