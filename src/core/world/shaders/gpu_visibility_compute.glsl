#[compute]
#version 450

// GPU Visibility Compute Shader
// Calculates visibility tier and fade for all objects in parallel
//
// Input: Object positions (vec4 per object)
// Output: Visibility state (vec4 per object)
// Also outputs NEAR tier changes for CPU processing

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Tier constants
const uint TIER_NEAR = 0u;
const uint TIER_MID = 1u;
const uint TIER_FAR = 2u;
const uint TIER_HIDDEN = 3u;

// Binding 0: Object positions [x, y, z, radius]
layout(set = 0, binding = 0, std430) restrict readonly buffer PositionsBuffer {
    vec4 positions[];
};

// Binding 1: Visibility output [visibility, fade, tier, prev_tier]
layout(set = 0, binding = 1, std430) restrict buffer VisibilityBuffer {
    vec4 visibility[];
};

// Binding 2: NEAR change count (atomic counter)
layout(set = 0, binding = 2, std430) restrict buffer ChangeCountBuffer {
    uint change_count;
};

// Binding 3: NEAR changes [global_idx, old_tier, new_tier, padding]
layout(set = 0, binding = 3, std430) restrict buffer ChangesBuffer {
    uvec4 changes[];
};

// Push constants
layout(push_constant) uniform PushConstants {
    vec4 camera_pos;           // xyz = position, w = unused
    vec4 thresholds;           // x = near_end, y = mid_end, z = far_end, w = fade_margin
    vec4 hysteresis;           // x = near_hyst, y = mid_hyst, z = unused, w = unused
    uvec4 counts;              // x = object_count, y = max_changes, z = unused, w = unused
} pc;

void main() {
    uint idx = gl_GlobalInvocationID.x;

    // Bounds check
    if (idx >= pc.counts.x) {
        return;
    }

    // Read position
    vec4 pos_data = positions[idx];
    vec3 obj_pos = pos_data.xyz;
    float radius = pos_data.w;

    // Skip objects at infinity (removed)
    if (obj_pos.x > 900000.0) {
        visibility[idx] = vec4(0.0, 0.0, float(TIER_HIDDEN), float(TIER_HIDDEN));
        return;
    }

    // Read previous state
    vec4 prev_state = visibility[idx];
    uint prev_tier = uint(prev_state.w);

    // Calculate distance to camera
    float dist = distance(obj_pos, pc.camera_pos.xyz);

    // Get thresholds
    float near_end = pc.thresholds.x;
    float mid_end = pc.thresholds.y;
    float far_end = pc.thresholds.z;
    float fade_margin = pc.thresholds.w;

    float near_hyst = pc.hysteresis.x;
    float mid_hyst = pc.hysteresis.y;

    // Determine tier with hysteresis
    uint new_tier = TIER_HIDDEN;

    if (prev_tier == TIER_NEAR) {
        // Currently NEAR: need to go past near_end + hysteresis to exit
        if (dist < near_end + near_hyst) {
            new_tier = TIER_NEAR;
        } else if (dist < mid_end) {
            new_tier = TIER_MID;
        } else if (dist < far_end) {
            new_tier = TIER_FAR;
        }
    } else if (prev_tier == TIER_MID) {
        // Currently MID: hysteresis on both boundaries
        if (dist < near_end - near_hyst) {
            new_tier = TIER_NEAR;
        } else if (dist < mid_end + mid_hyst) {
            new_tier = TIER_MID;
        } else if (dist < far_end) {
            new_tier = TIER_FAR;
        }
    } else if (prev_tier == TIER_FAR) {
        // Currently FAR: hysteresis on entry to MID
        if (dist < near_end - near_hyst) {
            new_tier = TIER_NEAR;
        } else if (dist < mid_end - mid_hyst) {
            new_tier = TIER_MID;
        } else if (dist < far_end) {
            new_tier = TIER_FAR;
        }
    } else {
        // Currently HIDDEN: standard thresholds
        if (dist < near_end) {
            new_tier = TIER_NEAR;
        } else if (dist < mid_end) {
            new_tier = TIER_MID;
        } else if (dist < far_end) {
            new_tier = TIER_FAR;
        }
    }

    // Calculate visibility (1.0 = fully visible, 0.0 = invisible)
    float vis = (new_tier != TIER_HIDDEN) ? 1.0 : 0.0;

    // Calculate fade based on distance within tier
    float fade = 1.0;

    if (new_tier == TIER_NEAR) {
        // Fade out approaching MID boundary
        float fade_start = near_end - fade_margin;
        if (dist > fade_start) {
            fade = 1.0 - (dist - fade_start) / fade_margin;
        }
    } else if (new_tier == TIER_MID) {
        // Fade in from NEAR boundary
        float fade_in_end = near_end + fade_margin;
        if (dist < fade_in_end) {
            fade = (dist - near_end) / fade_margin;
        }
        // Fade out approaching FAR boundary
        float fade_out_start = mid_end - fade_margin;
        if (dist > fade_out_start) {
            fade = min(fade, 1.0 - (dist - fade_out_start) / fade_margin);
        }
    } else if (new_tier == TIER_FAR) {
        // Fade in from MID boundary
        float fade_in_end = mid_end + fade_margin;
        if (dist < fade_in_end) {
            fade = (dist - mid_end) / fade_margin;
        }
        // Fade out approaching hidden
        float fade_out_start = far_end - fade_margin;
        if (dist > fade_out_start) {
            fade = min(fade, 1.0 - (dist - fade_out_start) / fade_margin);
        }
    }

    fade = clamp(fade, 0.0, 1.0);

    // Record NEAR tier changes for CPU processing
    // Changes involving NEAR tier need CPU handling for Node3D instantiation
    bool is_near_change = (new_tier == TIER_NEAR && prev_tier != TIER_NEAR) ||
                          (new_tier != TIER_NEAR && prev_tier == TIER_NEAR);

    if (is_near_change) {
        uint change_idx = atomicAdd(change_count, 1u);
        if (change_idx < pc.counts.y) {
            changes[change_idx] = uvec4(idx, prev_tier, new_tier, 0u);
        }
    }

    // Write output
    visibility[idx] = vec4(vis, fade, float(new_tier), float(prev_tier));
}
