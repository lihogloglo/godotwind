#[compute]
#version 450

// =============================================================================
// Unified Visibility Compute Shader for GPU-Driven Streaming
// =============================================================================
// Phase 2 of the GPU-driven streaming refactor. This shader calculates
// visibility, tier, and fade values for all objects in a single pass.
//
// Key Features:
// - Per-object tier calculation with hysteresis
// - Smooth fade calculation at tier boundaries
// - Sparse NEAR tier change output for CPU processing
// - Previous frame comparison for fade animation
//
// Output is designed to be compatible with MultiMesh INSTANCE_CUSTOM:
//   visibility_output[i] = vec4(visibility, fade, tier, flags)
//
// Where:
//   - visibility: 1.0 = visible, 0.0 = hidden
//   - fade: 0.0-1.0 fade amount for smooth transitions
//   - tier: 0=NEAR, 1=MID, 2=FAR, 3=HIDDEN
//   - flags: Reserved for future use
// =============================================================================

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Maximum NEAR tier changes we can track
const uint MAX_NEAR_CHANGES = 512u;

// Tier constants
const uint TIER_NEAR = 0u;
const uint TIER_MID = 1u;
const uint TIER_FAR = 2u;
const uint TIER_HIDDEN = 3u;

// Object positions (input)
// Layout: [x, y, z, batch_index] per object
layout(set = 0, binding = 0, std430) restrict readonly buffer Positions {
    vec4 positions[];
};

// Visibility output (this frame)
// Layout: [visibility, fade, tier, flags] per object
layout(set = 0, binding = 1, std430) restrict writeonly buffer VisibilityOutput {
    vec4 visibility_output[];
};

// Previous frame visibility (for fade calculation)
layout(set = 0, binding = 2, std430) restrict readonly buffer PrevVisibility {
    vec4 prev_visibility[];
};

// NEAR tier change counter (atomic)
layout(set = 0, binding = 3, std430) restrict coherent buffer NearChangeCount {
    uint near_change_count;
};

// NEAR tier changes (sparse output)
// Layout: [global_index, old_tier, new_tier, reserved] per change
layout(set = 0, binding = 4, std430) restrict buffer NearChanges {
    uvec4 near_changes[];
};

// Push constants for per-frame data
layout(push_constant, std430) uniform PushConstants {
    vec4 camera_pos;          // xyz = position, w = unused

    // Tier thresholds (squared)
    float near_end_sq;        // 150² = 22500
    float mid_end_sq;         // 500² = 250000
    float far_end_sq;         // 5000² = 25000000
    float max_view_dist_sq;   // Maximum view distance squared

    // Fade margins (linear, not squared)
    float fade_margin_near;   // 50m
    float fade_margin_mid;    // 50m
    float _padding1;
    float _padding2;

    uint object_count;
    uint _pad1;
    uint _pad2;
    uint _pad3;
} pc;

// Calculate tier from squared distance
uint get_tier_from_distance(float dist_sq) {
    if (dist_sq < pc.near_end_sq) {
        return TIER_NEAR;
    } else if (dist_sq < pc.mid_end_sq) {
        return TIER_MID;
    } else if (dist_sq < pc.far_end_sq) {
        return TIER_FAR;
    }
    return TIER_HIDDEN;
}

// Calculate fade amount at tier boundaries
// Returns 1.0 when fully in tier, 0.0-1.0 at boundaries
float calculate_fade(float dist, uint tier) {
    float fade = 1.0;

    // NEAR-MID boundary (fade out of NEAR, fade into MID)
    float near_boundary = sqrt(pc.near_end_sq);
    if (dist > near_boundary - pc.fade_margin_near && dist < near_boundary + pc.fade_margin_near) {
        if (tier == TIER_NEAR) {
            // Fading out of NEAR
            fade = 1.0 - smoothstep(near_boundary - pc.fade_margin_near, near_boundary, dist);
        } else if (tier == TIER_MID) {
            // Fading into MID
            fade = smoothstep(near_boundary, near_boundary + pc.fade_margin_near, dist);
        }
    }

    // MID-FAR boundary
    float mid_boundary = sqrt(pc.mid_end_sq);
    if (dist > mid_boundary - pc.fade_margin_mid && dist < mid_boundary + pc.fade_margin_mid) {
        if (tier == TIER_MID) {
            // Fading out of MID
            float out_fade = 1.0 - smoothstep(mid_boundary - pc.fade_margin_mid, mid_boundary, dist);
            fade = min(fade, out_fade);
        } else if (tier == TIER_FAR) {
            // Fading into FAR
            fade = smoothstep(mid_boundary, mid_boundary + pc.fade_margin_mid, dist);
        }
    }

    return clamp(fade, 0.0, 1.0);
}

// Apply hysteresis to prevent tier flickering
// prev_tier: Object's previous tier
// raw_tier: Tier from pure distance calculation
// dist_sq: Squared distance
uint apply_hysteresis(uint prev_tier, uint raw_tier, float dist_sq) {
    // No previous tier or same tier - use raw
    if (prev_tier == TIER_HIDDEN || prev_tier == raw_tier) {
        return raw_tier;
    }

    // Hysteresis margins (squared for comparison)
    float near_hyst = 40.0;
    float mid_hyst = 60.0;

    float near_exit_sq = (sqrt(pc.near_end_sq) + near_hyst);
    near_exit_sq *= near_exit_sq;

    float near_enter_sq = (sqrt(pc.near_end_sq) - near_hyst);
    near_enter_sq *= near_enter_sq;

    float mid_exit_sq = (sqrt(pc.mid_end_sq) + mid_hyst);
    mid_exit_sq *= mid_exit_sq;

    float mid_enter_sq = (sqrt(pc.mid_end_sq) - mid_hyst);
    mid_enter_sq *= mid_enter_sq;

    // Apply hysteresis based on direction of movement
    if (prev_tier == TIER_NEAR) {
        // Must exceed exit threshold to leave NEAR
        if (dist_sq < near_exit_sq) {
            return TIER_NEAR;
        }
    } else if (raw_tier == TIER_NEAR) {
        // Must be below enter threshold to enter NEAR
        if (dist_sq > near_enter_sq) {
            return prev_tier;
        }
    }

    if (prev_tier == TIER_MID) {
        // Must exceed exit threshold to leave MID
        if (dist_sq > near_enter_sq && dist_sq < mid_exit_sq) {
            return TIER_MID;
        }
    } else if (raw_tier == TIER_MID) {
        // Must be in enter range to enter MID
        if (dist_sq < near_exit_sq || dist_sq > mid_enter_sq) {
            return prev_tier;
        }
    }

    return raw_tier;
}

void main() {
    uint idx = gl_GlobalInvocationID.x;

    // Bounds check
    if (idx >= pc.object_count) {
        return;
    }

    // Load object position
    vec4 pos = positions[idx];

    // Calculate distance to camera
    vec3 delta = pos.xyz - pc.camera_pos.xyz;
    float dist_sq = dot(delta, delta);
    float dist = sqrt(dist_sq);

    // Get raw tier from distance
    uint raw_tier = get_tier_from_distance(dist_sq);

    // Load previous frame data
    vec4 prev = prev_visibility[idx];
    uint prev_tier = uint(prev.z);

    // Apply hysteresis
    uint new_tier = apply_hysteresis(prev_tier, raw_tier, dist_sq);

    // Calculate visibility and fade
    float visibility = (new_tier != TIER_HIDDEN) ? 1.0 : 0.0;
    float fade = calculate_fade(dist, new_tier);

    // Write output
    visibility_output[idx] = vec4(visibility, fade, float(new_tier), 0.0);

    // Track NEAR tier changes for CPU
    bool tier_changed = (new_tier != prev_tier);
    bool involves_near = (new_tier == TIER_NEAR || prev_tier == TIER_NEAR);

    if (tier_changed && involves_near) {
        uint slot = atomicAdd(near_change_count, 1u);
        if (slot < MAX_NEAR_CHANGES) {
            near_changes[slot] = uvec4(idx, prev_tier, new_tier, 0u);
        }
    }
}
