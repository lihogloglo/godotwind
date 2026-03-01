# Spec: HLOD Prebake Pipeline

**Status:** Draft
**Owner:** gemini
**Priority:** High (Next-Gen Scalability)

## Context
Individual object rendering at distance (MID/FAR tiers) causes draw call bottlenecks. While GPU-driven rendering solves some of this via batching, true "next-gen" performance requires **Hierarchical Level of Detail (HLOD)**: merging multiple nearby objects into single, simplified meshes at distance.

## Goals
- **Draw Call reduction:** 200+ MID-tier objects in a cell merged into ~4-8 HLOD clusters.
- **Poly Count reduction:** Use `MeshOptimizer` for aggressive simplification of merged clusters.
- **Seamless transitions:** Ensure HLOD clusters match the visual appearance of their constituent objects.

## Architecture

### 1. The Prebake Clustering Phase
During the `model_prebaker.gd` execution:
1.  **Spatially Cluster:** For each cell, group objects into ~50m blocks using a grid-based spatial index.
2.  **Filter Significant Objects:** Only cluster static objects (rocks, buildings, flora). Skip NPCs, doors, and dynamic items.
3.  **Merge Geometry:** Combine the meshes of all objects in a cluster into a single vertex/index buffer.

### 2. The Simplification & Atlasing Phase
For each merged cluster:
1.  **Atlas Generation**: Generate a combined texture atlas for the cluster. Since HLOD is for distant objects, a single 1024x1024 atlas for the whole cluster is sufficient. Use Godot's `AtlasTexture` or a custom packing script.
2.  **Decimate**: Use the **MeshOptimizer GDExtension** (or `SurfaceTool.generate_lod()`) to simplify the merged mesh by 70-90%.
3.  **Save HLOD Scene**: Store as `.hlod.res` in the cache folder.

### 3. Runtime & Transitions
We will use **VisibilityRange Hysteresis** to avoid "popping":
- **HLOD Cluster**: Visible at >200m.
- **Individual Objects**: Visible at <180m.
- **Overlap Zone (180-200m)**: Both exist. We use a custom **Alpha Dither Shader** (on the individual objects' materials and the HLOD material) to perform a cross-dissolve based on camera distance.

## Implementation Details

### Atlasing
- **Baking**: Use a `Viewport`-based baker to render the different materials onto a single atlas at prebake time.
- **UV Remapping**: Scale and offset the UVs of the merged mesh to match the new atlas.

### Mesh Simplification
- Use the `MeshOptimizer` library directly via GDExtension to benefit from high-quality decimation that preserves silhouettes.


## Success Criteria
- [ ] HLOD cluster rendering matches original objects at >150m.
- [ ] 5x-10x reduction in draw calls for MID/FAR tiers.
- [ ] Zero hitching during HLOD streaming.

## Next Steps
1. Create HLOD prototype using `MeshOptimizer`.
2. Update `model_prebaker.gd` to include an HLOD pass.
3. Define the visibility transition strategy (Cluster↔Individual).
