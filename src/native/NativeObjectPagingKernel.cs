using Godot;
using System.Collections.Generic;

namespace Godotwind.Native;

/// <summary>
/// Hot merge math for chunk-level geometry merging (OpenMW ObjectPaging pattern).
/// GDScript side owns the orchestration (ESM iteration, LRU cache, RS instance
/// management, ImporterMesh LOD generation); this class owns the per-vertex
/// transform loops, material-hash grouping, and PackedArray concatenation —
/// the CPU-bound work that benefits from C# tight loops + typed arrays.
///
/// Input contract (see GDScript <c>ObjectPagingKernel</c>):
///   <c>triplets</c> is a Godot Array of [surfaceArrays, fullTransform, material]
///   tuples. <c>surfaceArrays</c> is a <see cref="Godot.Collections.Array"/>
///   as returned by <see cref="ArrayMesh.SurfaceGetArrays(int)"/>.
///   <c>fullTransform</c> is the world-space transform of this surface
///   relative to the chunk origin (caller pre-subtracts chunk origin from the
///   translation). <c>material</c> is the resolved material (override or per-
///   surface), may be null.
///
/// Thread safety: all methods are pure — no shared state, no Godot scene tree
/// access. Safe to call from <see cref="WorkerThreadPool"/> tasks.
///
/// Performance: the hot vertex loop (<see cref="TransformVertexArrays"/>) is
/// the primary target. Typical chunk = 15-60 refs × 1-4 sub-meshes ×
/// 100-2000 verts = 10k-500k vertex transforms per merge. GDScript hits
/// ~3-5µs/vert in `Vector3[]` loops; C# hits ~0.1-0.3µs/vert with the JIT
/// inlining `Transform3D * Vector3`.
/// </summary>
[GlobalClass]
public partial class NativeObjectPagingKernel : RefCounted
{
    private const int MaxSurfaces = 250;

    // Cached ARRAY_* indices to avoid repeated enum->int casts.
    private const int ArrayVertex = (int)Mesh.ArrayType.Vertex;
    private const int ArrayNormal = (int)Mesh.ArrayType.Normal;
    private const int ArrayTangent = (int)Mesh.ArrayType.Tangent;
    private const int ArrayColor = (int)Mesh.ArrayType.Color;
    private const int ArrayTexUv = (int)Mesh.ArrayType.TexUV;
    private const int ArrayTexUv2 = (int)Mesh.ArrayType.TexUV2;
    private const int ArrayIndex = (int)Mesh.ArrayType.Index;
    private const int ArrayMax = (int)Mesh.ArrayType.Max;

    /// <summary>
    /// Apply a Transform3D to every element of a <see cref="Vector3"/> array.
    /// Allocates and returns a new array — caller retains the original.
    /// </summary>
    private static Vector3[] TransformVertexArrays(Vector3[] src, Transform3D xform)
    {
        int count = src.Length;
        var dst = new Vector3[count];
        for (int i = 0; i < count; i++)
            dst[i] = xform * src[i];
        return dst;
    }

    private static Vector3[] TransformNormalArrays(Vector3[] src, Basis normalBasis)
    {
        int count = src.Length;
        var dst = new Vector3[count];
        for (int i = 0; i < count; i++)
            dst[i] = (normalBasis * src[i]).Normalized();
        return dst;
    }

    private static int[] IdentityIndices(int vertCount)
    {
        var indices = new int[vertCount];
        for (int i = 0; i < vertCount; i++)
            indices[i] = i;
        return indices;
    }

    /// <summary>
    /// Merge all surface triplets into one <see cref="ArrayMesh"/> (no LOD chain).
    /// Caller runs <c>ImporterMesh.generate_lods()</c> on the result separately.
    ///
    /// <para>Returns null if the triplets produce no geometry.</para>
    /// </summary>
    public ArrayMesh MergeSurfaceTriplets(Godot.Collections.Array triplets)
    {
        // material instance ID -> {material, list of surface-array dicts ready to concat}
        var matGroups = new Dictionary<ulong, MatGroup>();

        foreach (Variant triplet in triplets)
        {
            var trip = triplet.AsGodotArray();
            if (trip.Count < 3) continue;

            var srcArrays = trip[0].AsGodotArray();
            var fullXform = trip[1].AsTransform3D();
            var material = trip[2].As<Material>();

            if (srcArrays.Count <= ArrayVertex) continue;
            var srcVertsVariant = srcArrays[ArrayVertex];
            if (srcVertsVariant.VariantType != Variant.Type.PackedVector3Array) continue;
            var srcVerts = srcVertsVariant.AsVector3Array();
            if (srcVerts.Length == 0) continue;

            // Build the transformed arrays snapshot. We build a fresh
            // Godot.Collections.Array per triplet so downstream concat can
            // iterate uniformly without caring whether the xform was identity.
            var workArrays = new Godot.Collections.Array();
            workArrays.Resize(ArrayMax);

            // Fuzzy identity check matches the pre-extraction GDScript contract.
            // Post-multiply + chunk-origin subtract rarely produces a bit-exact
            // identity; an exact == would re-transform refs the old kernel skipped.
            bool isIdentity = fullXform.IsEqualApprox(Transform3D.Identity);
            if (isIdentity)
            {
                workArrays[ArrayVertex] = srcVerts;
            }
            else
            {
                workArrays[ArrayVertex] = TransformVertexArrays(srcVerts, fullXform);
            }

            // Normals
            if (srcArrays.Count > ArrayNormal)
            {
                var nVar = srcArrays[ArrayNormal];
                if (nVar.VariantType == Variant.Type.PackedVector3Array)
                {
                    var srcNormals = nVar.AsVector3Array();
                    if (srcNormals.Length > 0)
                    {
                        if (isIdentity)
                            workArrays[ArrayNormal] = srcNormals;
                        else
                        {
                            var nb = fullXform.Basis.Inverse().Transposed();
                            workArrays[ArrayNormal] = TransformNormalArrays(srcNormals, nb);
                        }
                    }
                }
            }

            // Pass-through: tangents, colors, uvs, uvs2 (not transformed)
            CopyArrayIfPresent(srcArrays, workArrays, ArrayTangent, Variant.Type.PackedFloat32Array);
            CopyArrayIfPresent(srcArrays, workArrays, ArrayColor, Variant.Type.PackedColorArray);
            CopyArrayIfPresent(srcArrays, workArrays, ArrayTexUv, Variant.Type.PackedVector2Array);
            CopyArrayIfPresent(srcArrays, workArrays, ArrayTexUv2, Variant.Type.PackedVector2Array);

            // Index buffer — ensure one exists
            int[] indices;
            if (srcArrays.Count > ArrayIndex
                && srcArrays[ArrayIndex].VariantType == Variant.Type.PackedInt32Array)
            {
                var srcIndices = srcArrays[ArrayIndex].AsInt32Array();
                if (srcIndices.Length > 0)
                {
                    indices = srcIndices;
                }
                else
                {
                    indices = IdentityIndices(srcVerts.Length);
                }
            }
            else
            {
                indices = IdentityIndices(srcVerts.Length);
            }
            workArrays[ArrayIndex] = indices;

            ulong matId = material != null ? (ulong)material.GetInstanceId() : 0UL;
            if (!matGroups.TryGetValue(matId, out var group))
            {
                group = new MatGroup { Material = material, ArraysList = new Godot.Collections.Array() };
                matGroups[matId] = group;
            }
            group.ArraysList.Add(workArrays);
        }

        if (matGroups.Count == 0)
            return null;

        // Flatten each material group into a single surface.
        // Iterate matGroups in matId order so run-to-run output is deterministic
        // regardless of hash-table iteration order (C# Dictionary does not
        // guarantee insertion order; GDScript Dictionary does, so we match the
        // stronger contract explicitly here).
        var flatSurfaces = new List<FlatSurface>();
        var sortedMatIds = new List<ulong>(matGroups.Keys);
        sortedMatIds.Sort();
        foreach (var matId in sortedMatIds)
        {
            var group = matGroups[matId];
            Godot.Collections.Array arrays;
            if (group.ArraysList.Count == 1)
                arrays = group.ArraysList[0].AsGodotArray();
            else
                arrays = ConcatenateSurfaceArrays(group.ArraysList);

            if (arrays.Count == 0) continue;
            var verts = arrays[ArrayVertex].AsVector3Array();
            flatSurfaces.Add(new FlatSurface { Arrays = arrays, Material = group.Material, VertCount = verts.Length });
        }

        if (flatSurfaces.Count == 0)
            return null;

        // Handle surface-count overflow (Godot hard cap 256, leave headroom).
        // TODO(paging-phase-N): overflow surfaces get Material = null, losing
        // their original material (pre-existing behaviour from the GDScript
        // kernel — kept verbatim in Phase 1 extraction, not a new regression).
        // A proper fix is a fallback "combine by closest albedo + texture hash"
        // once we see a real chunk hit >250 materials in bench_progressive.
        if (flatSurfaces.Count > MaxSurfaces)
        {
            flatSurfaces.Sort((a, b) => b.VertCount.CompareTo(a.VertCount));
            var overflow = new Godot.Collections.Array();
            for (int i = MaxSurfaces - 1; i < flatSurfaces.Count; i++)
                overflow.Add(flatSurfaces[i].Arrays);
            flatSurfaces.RemoveRange(MaxSurfaces - 1, flatSurfaces.Count - (MaxSurfaces - 1));
            var combined = ConcatenateSurfaceArrays(overflow);
            if (combined.Count > 0)
                flatSurfaces.Add(new FlatSurface { Arrays = combined, Material = null, VertCount = 0 });
        }

        var mergedMesh = new ArrayMesh();
        foreach (var entry in flatSurfaces)
        {
            mergedMesh.AddSurfaceFromArrays(Mesh.PrimitiveType.Triangles, entry.Arrays);
            if (entry.Material != null)
                mergedMesh.SurfaceSetMaterial(mergedMesh.GetSurfaceCount() - 1, entry.Material);
        }

        if (mergedMesh.GetSurfaceCount() == 0)
            return null;

        return mergedMesh;
    }

    /// <summary>
    /// Concatenate multiple surface-array blocks (same material) into one surface.
    /// Offsets index buffers to account for merged vertex base. Pads missing
    /// attributes to the union of what appears across the inputs.
    /// </summary>
    public Godot.Collections.Array ConcatenateSurfaceArrays(Godot.Collections.Array arraysList)
    {
        var result = new Godot.Collections.Array();
        if (arraysList.Count == 0) return result;

        // Probe for attribute presence across the union
        bool hasNormals = false, hasTangents = false, hasColors = false, hasUvs = false, hasUvs2 = false;
        foreach (Variant pv in arraysList)
        {
            var probe = pv.AsGodotArray();
            if (!hasNormals && probe.Count > ArrayNormal && probe[ArrayNormal].VariantType == Variant.Type.PackedVector3Array)
                hasNormals = true;
            if (!hasTangents && probe.Count > ArrayTangent && probe[ArrayTangent].VariantType == Variant.Type.PackedFloat32Array)
                hasTangents = true;
            if (!hasColors && probe.Count > ArrayColor && probe[ArrayColor].VariantType == Variant.Type.PackedColorArray)
                hasColors = true;
            if (!hasUvs && probe.Count > ArrayTexUv && probe[ArrayTexUv].VariantType == Variant.Type.PackedVector2Array)
                hasUvs = true;
            if (!hasUvs2 && probe.Count > ArrayTexUv2 && probe[ArrayTexUv2].VariantType == Variant.Type.PackedVector2Array)
                hasUvs2 = true;
        }

        // First pass: total vertex count for allocation
        int totalVerts = 0;
        foreach (Variant av in arraysList)
        {
            var arrays = av.AsGodotArray();
            if (arrays.Count <= ArrayVertex) continue;
            var vv = arrays[ArrayVertex];
            if (vv.VariantType != Variant.Type.PackedVector3Array) continue;
            totalVerts += vv.AsVector3Array().Length;
        }
        if (totalVerts == 0) return result;

        var allVerts = new Vector3[totalVerts];
        var allNormals = hasNormals ? new Vector3[totalVerts] : null;
        var allTangents = hasTangents ? new float[totalVerts * 4] : null;
        var allColors = hasColors ? new Color[totalVerts] : null;
        var allUvs = hasUvs ? new Vector2[totalVerts] : null;
        var allUvs2 = hasUvs2 ? new Vector2[totalVerts] : null;
        var allIndices = new List<int>(totalVerts); // index count isn't known up front

        int baseVertex = 0;
        foreach (Variant av in arraysList)
        {
            var arrays = av.AsGodotArray();
            if (arrays.Count <= ArrayVertex) continue;
            var vv = arrays[ArrayVertex];
            if (vv.VariantType != Variant.Type.PackedVector3Array) continue;

            var verts = vv.AsVector3Array();
            int vertCount = verts.Length;
            System.Array.Copy(verts, 0, allVerts, baseVertex, vertCount);

            if (hasNormals) CopyOrPadVec3(arrays, ArrayNormal, allNormals, baseVertex, vertCount, Vector3.Up);
            if (hasTangents) CopyOrPadFloat4(arrays, ArrayTangent, allTangents, baseVertex * 4, vertCount);
            if (hasColors) CopyOrPadColor(arrays, ArrayColor, allColors, baseVertex, vertCount, Colors.White);
            if (hasUvs) CopyOrPadVec2(arrays, ArrayTexUv, allUvs, baseVertex, vertCount);
            if (hasUvs2) CopyOrPadVec2(arrays, ArrayTexUv2, allUvs2, baseVertex, vertCount);

            // Indices — offset by baseVertex
            if (arrays.Count > ArrayIndex && arrays[ArrayIndex].VariantType == Variant.Type.PackedInt32Array)
            {
                var inds = arrays[ArrayIndex].AsInt32Array();
                if (inds.Length > 0)
                {
                    for (int i = 0; i < inds.Length; i++)
                        allIndices.Add(inds[i] + baseVertex);
                }
                else
                {
                    for (int i = 0; i < vertCount; i++)
                        allIndices.Add(i + baseVertex);
                }
            }
            else
            {
                for (int i = 0; i < vertCount; i++)
                    allIndices.Add(i + baseVertex);
            }

            baseVertex += vertCount;
        }

        result.Resize(ArrayMax);
        result[ArrayVertex] = allVerts;
        if (hasNormals) result[ArrayNormal] = allNormals;
        if (hasTangents) result[ArrayTangent] = allTangents;
        if (hasColors) result[ArrayColor] = allColors;
        if (hasUvs) result[ArrayTexUv] = allUvs;
        if (hasUvs2) result[ArrayTexUv2] = allUvs2;
        result[ArrayIndex] = allIndices.ToArray();
        return result;
    }

    /// <summary>
    /// Estimate merged <see cref="ArrayMesh"/> memory in bytes.
    /// pos(12) + normal(12) + uv(8) + index(4) + overhead ≈ 48 bytes/vert,
    /// scaled ×1.5 for LOD chain overhead.
    /// </summary>
    public int EstimateMeshBytes(ArrayMesh mesh)
    {
        int total = 0;
        int surfaceCount = mesh.GetSurfaceCount();
        for (int si = 0; si < surfaceCount; si++)
        {
            var arrays = mesh.SurfaceGetArrays(si);
            if (arrays.Count <= ArrayVertex) continue;
            var v = arrays[ArrayVertex];
            if (v.VariantType == Variant.Type.PackedVector3Array)
                total += v.AsVector3Array().Length * 72;
        }
        return total;
    }

    #region Private helpers

    private static void CopyArrayIfPresent(Godot.Collections.Array src, Godot.Collections.Array dst, int index, Variant.Type expected)
    {
        if (src.Count <= index) return;
        var v = src[index];
        if (v.VariantType == expected)
            dst[index] = v;
    }

    private static void CopyOrPadVec3(Godot.Collections.Array arrays, int idx, Vector3[] dst, int baseVertex, int vertCount, Vector3 pad)
    {
        if (arrays.Count > idx && arrays[idx].VariantType == Variant.Type.PackedVector3Array)
        {
            var src = arrays[idx].AsVector3Array();
            if (src.Length == vertCount)
            {
                System.Array.Copy(src, 0, dst, baseVertex, vertCount);
                return;
            }
        }
        for (int i = 0; i < vertCount; i++) dst[baseVertex + i] = pad;
    }

    private static void CopyOrPadVec2(Godot.Collections.Array arrays, int idx, Vector2[] dst, int baseVertex, int vertCount)
    {
        if (arrays.Count > idx && arrays[idx].VariantType == Variant.Type.PackedVector2Array)
        {
            var src = arrays[idx].AsVector2Array();
            if (src.Length == vertCount)
            {
                System.Array.Copy(src, 0, dst, baseVertex, vertCount);
                return;
            }
        }
        // zero-pad (default Vector2)
    }

    private static void CopyOrPadColor(Godot.Collections.Array arrays, int idx, Color[] dst, int baseVertex, int vertCount, Color pad)
    {
        if (arrays.Count > idx && arrays[idx].VariantType == Variant.Type.PackedColorArray)
        {
            var src = arrays[idx].AsColorArray();
            if (src.Length == vertCount)
            {
                System.Array.Copy(src, 0, dst, baseVertex, vertCount);
                return;
            }
        }
        for (int i = 0; i < vertCount; i++) dst[baseVertex + i] = pad;
    }

    private static void CopyOrPadFloat4(Godot.Collections.Array arrays, int idx, float[] dst, int baseOffset, int vertCount)
    {
        if (arrays.Count > idx && arrays[idx].VariantType == Variant.Type.PackedFloat32Array)
        {
            var src = arrays[idx].AsFloat32Array();
            if (src.Length == vertCount * 4)
            {
                System.Array.Copy(src, 0, dst, baseOffset, vertCount * 4);
                return;
            }
        }
        // zero-pad
    }

    private sealed class MatGroup
    {
        public Material Material = null!;
        public Godot.Collections.Array ArraysList = null!;
    }

    private sealed class FlatSurface
    {
        public Godot.Collections.Array Arrays = null!;
        public Material Material = null!;
        public int VertCount;
    }

    #endregion
}
