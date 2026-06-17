# Godot Performance Observability Notes

Use this reference when setting up or reviewing Pillar 3.0 instrumentation.

## Official Godot Surfaces

- `Performance.get_monitor()` exposes engine monitor values such as FPS, frame
  time, physics time, memory, object counts, draw calls, primitives, video
  memory, physics counts, navigation counts, and pipeline compilation counters.
  Some monitors are debug-only or update with delay.
  Source: https://docs.godotengine.org/en/stable/classes/class_performance.html
- `Performance.add_custom_monitor()` lets the project expose custom values in
  the editor Debugger > Monitors panel. Use this for Godotwind-specific metrics:
  streaming queue depth, loaded cells, async request count, cell publish budget,
  cache hits/misses, first-playable gates, and benchmark validity flags.
  Source: https://docs.godotengine.org/en/stable/tutorials/scripting/debug/custom_performance_monitors.html
- Godot's profiler is intentionally off by default because profiling itself is
  performance-intensive. Treat profiler sessions as diagnostic runs, not as
  always-on benchmark truth. The current docs also note that the editor profiler
  does not support C# scripts; use external .NET profilers for C# hot paths.
  Source: https://docs.godotengine.org/en/stable/tutorials/scripting/debug/the_profiler.html
- For startup/shutdown profiling, Godot 4.6 docs mention `--quit` with
  `--path <project>` as a way to exit immediately after startup when using
  external profilers.
  Source: https://docs.godotengine.org/en/4.6/engine_details/development/profiling/index.html
- Godot 4.6 added ObjectDB snapshots and comparisons for live object tracking.
  This is relevant for streaming unload tests and leak growth after repeated
  cell transitions.
  Source: https://godotengine.org/releases/4.6/
- Godot's server APIs can help when dealing with tens of thousands of instances
  that must be processed every frame, after simpler optimization avenues are
  exhausted.
  Source: https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html

## Godotwind Interpretation

- Built-in monitors are good for frame/render/memory/object/physics totals.
- Custom monitors are the right surface for project-specific streaming state.
- JSON/CSV summaries are the right surface for future agents.
- Visual/editor profiler output is useful for diagnosis but hard for agents to
  compare across sessions unless converted into structured reports.
- ObjectDB snapshots belong in a later leak-diagnostic slice after the basic
  benchmark report contract is stable.
