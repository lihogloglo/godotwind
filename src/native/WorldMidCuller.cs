using Godot;
using System;
using System.Runtime.CompilerServices;

namespace Godotwind.Native;

/// <summary>
/// Distance-cull + packed-buffer writer for the Phase 3 world-scoped MID
/// MultiMesh registry. GDScript-owned slot bookkeeping (freelist, slot_live,
/// slot_transforms, slot_custom_data) is passed in as packed arrays; C#
/// iterates live slots, rejects those past <c>maxDistSq</c>, and writes the
/// survivors back-to-back into a fresh output buffer that the caller uploads
/// via <c>RenderingServer.multimesh_set_buffer</c>.
///
/// <para>Input / output contract matches
/// <see cref="PrototypeBatch.cull_and_upload"/> (the GDScript fallback).
/// Layout constants must stay in sync:</para>
/// <list type="bullet">
///   <item><description>slot_transforms stride = 12 (row-major 3×4)</description></item>
///   <item><description>slot_custom_data stride = 4 (INSTANCE_CUSTOM)</description></item>
///   <item><description>packed output stride = 16 (12 + 4)</description></item>
/// </list>
///
/// <para>Frustum culling is deliberately out of scope — the engine's
/// auto-computed MultiMesh AABB already frustum-culls the whole batch at
/// world scale. Per-slot frustum would pay only when the camera is inside
/// a dense batch's AABB but looking away; profile before adding.</para>
///
/// <para>Thread safety: pure function. No shared state, no Godot scene
/// tree access. Safe to call concurrently from multiple batches (e.g. a
/// future <c>Parallel.For</c> driver over the registry's batch list),
/// but the current driver runs single-threaded from
/// <c>native_streaming_manager._process</c>.</para>
/// </summary>
[GlobalClass]
public partial class WorldMidCuller : RefCounted
{
    /// <summary>Stride of a single slot's transform row in slotTransforms.</summary>
    public const int TransformStride = 12;

    /// <summary>Stride of a single slot's custom-data row in slotCustomData.</summary>
    public const int CustomDataStride = 4;

    /// <summary>Combined stride in the packed output buffer.</summary>
    public const int PackedStride = TransformStride + CustomDataStride;

    /// <summary>
    /// Cull + pack. Returns a Godot Dictionary containing the visible slot
    /// count and a pre-allocated output buffer sized
    /// <c>slotCapacity * PackedStride</c> floats. The tail past
    /// <c>visible * PackedStride</c> is zero-filled (from the fresh
    /// <c>new float[...]</c> allocation) so stale transforms can't leak
    /// through to the GPU when visible_instance_count overestimates.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveOptimization)]
    public Godot.Collections.Dictionary CullAndPack(
        byte[] slotLive,
        float[] slotTransforms,
        float[] slotCustomData,
        Vector3 cameraPos,
        float maxDistSq,
        int slotCapacity)
    {
        var outBuffer = new float[slotCapacity * PackedStride];
        int visible = 0;
        int outOff = 0;
        // Nearest live-slot distance — fed back to GDScript for the per-batch
        // dynamic shadow toggle. Tracked over ALL live slots (not just visible
        // ones) so shadow state survives the max_dist_sq visible cull.
        float nearestDistSq = float.PositiveInfinity;

        float camX = cameraPos.X;
        float camY = cameraPos.Y;
        float camZ = cameraPos.Z;

        // Bounds-check hoist: the GDScript caller guarantees the input
        // arrays are sized slotCapacity * stride. We skip per-iter
        // Array.Length checks because the JIT can prove the pattern from
        // these locals.
        int liveLen = slotLive.Length;
        int trsLen = slotTransforms.Length;
        int cdLen = slotCustomData.Length;
        int cap = slotCapacity;
        if (liveLen < cap) cap = liveLen;
        if (trsLen < cap * TransformStride) cap = trsLen / TransformStride;
        if (cdLen < cap * CustomDataStride) cap = cdLen / CustomDataStride;

        for (int slot = 0; slot < cap; slot++)
        {
            if (slotLive[slot] == 0) continue;

            int trsOff = slot * TransformStride;
            // Origin components are at indices 3, 7, 11 (last column of
            // each of the 3 row-major rows — matches native_impostor_renderer
            // layout and set_slot_transform packing).
            float ox = slotTransforms[trsOff + 3];
            float oy = slotTransforms[trsOff + 7];
            float oz = slotTransforms[trsOff + 11];

            float dx = ox - camX;
            float dy = oy - camY;
            float dz = oz - camZ;
            float distSq = dx * dx + dy * dy + dz * dz;
            if (distSq < nearestDistSq) nearestDistSq = distSq;
            if (distSq > maxDistSq) continue;

            // 12-float transform row — block copy (JIT-friendly).
            Array.Copy(slotTransforms, trsOff, outBuffer, outOff, TransformStride);
            // 4-float custom data row.
            Array.Copy(slotCustomData, slot * CustomDataStride,
                       outBuffer, outOff + TransformStride, CustomDataStride);

            outOff += PackedStride;
            visible++;
        }

        return new Godot.Collections.Dictionary
        {
            { "visible", visible },
            { "buffer", outBuffer },
            { "nearest_dist_sq", nearestDistSq },
        };
    }
}
