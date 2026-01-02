#[compute]
#version 450

// GPU Compute Shader for Visibility Tier Calculations
// =====================================================
// Processes thousands of objects in parallel to determine visibility tiers.
// Takes object positions as input, outputs tier assignments per object.
//
// This replaces the O(n) GDScript loop in DistanceTierManager.update_visibility()
// with massively parallel GPU execution, reducing 20ms to <1ms for 10,000 objects.
//
// SPARSE READBACK OPTIMIZATION:
// Instead of reading back ALL object tiers every frame, we use an atomic counter
// and compact buffer to output ONLY the objects that changed tier. This reduces
// CPU readback from O(n) to O(changes), typically <1% of objects per frame.
//
// Tier System:
//   0 = NEAR (0-150m): Full Node3D with physics
//   1 = MID (150-500m): MultiMesh LOD instances
//   2 = FAR (500-5000m): Octahedral impostors
//   3 = HIDDEN (beyond FAR): Not rendered
//
// Hysteresis prevents tier flickering at boundaries:
//   - Objects must move further than the threshold to change tiers
//   - Different hysteresis values at each boundary

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Maximum number of tier changes we can track per frame
// If exceeded, remaining changes are still written to curr_tiers but not to compact buffer
const uint MAX_CHANGES = 4096u;

// Object position data (input)
// Each object has 4 floats: x, y, z, padding
layout(set = 0, binding = 0, std430) restrict readonly buffer ObjectPositions {
    vec4 positions[];
};

// Previous tier assignments (input for hysteresis)
// Each object has 1 uint: tier (0-3)
layout(set = 0, binding = 1, std430) restrict readonly buffer PreviousTiers {
    uint prev_tiers[];
};

// Current tier assignments (output)
// Each object has 1 uint: tier (0-3)
layout(set = 0, binding = 2, std430) restrict writeonly buffer CurrentTiers {
    uint curr_tiers[];
};

// Tier change flags (output) - 1 if tier changed this frame, 0 otherwise
// DEPRECATED: Kept for backward compatibility, prefer using sparse buffers below
layout(set = 0, binding = 3, std430) restrict buffer TierChanges {
    uint tier_changed[];
};

// SPARSE READBACK: Atomic counter for number of tier changes this frame
// Reset to 0 by CPU before dispatch, incremented atomically by each changing object
layout(set = 0, binding = 4, std430) restrict coherent buffer ChangeCounter {
    uint change_count;
};

// SPARSE READBACK: Compact buffer of changed object indices
// Contains buffer indices (not external IDs) of objects that changed tier
// CPU reads only [0..change_count-1] entries instead of all objects
layout(set = 0, binding = 5, std430) restrict buffer ChangedIndices {
    uint changed_indices[];
};

// SPARSE READBACK: Packed change data for each changed object
// Format: (buffer_index << 8) | (old_tier << 4) | new_tier
// Allows CPU to know both old and new tier without reading prev_tiers buffer
layout(set = 0, binding = 6, std430) restrict buffer ChangedData {
    uint changed_data[];
};

// Push constants for camera position and tier thresholds
// Using push constants for frequently-updated data (camera position)
// Total size: 80 bytes (must match GDScript exactly)
layout(push_constant) uniform PushConstants {
    vec4 camera_pos;           // xyz = position, w = unused (16 bytes, offset 0)

    // Tier end distances (squared to avoid sqrt in shader)
    float near_end_sq;         // 150m^2 = 22500 (4 bytes, offset 16)
    float mid_end_sq;          // 500m^2 = 250000 (4 bytes, offset 20)
    float far_end_sq;          // 5000m^2 = 25000000 (4 bytes, offset 24)
    float max_view_dist_sq;    // Maximum view distance squared (4 bytes, offset 28)

    // Hysteresis thresholds (squared)
    // These are the TOTAL distance thresholds with hysteresis applied
    float near_exit_sq;        // (near_end + hysteresis)^2 - leave NEAR (4 bytes, offset 32)
    float near_enter_sq;       // (near_end - hysteresis)^2 - enter NEAR (4 bytes, offset 36)
    float mid_exit_sq;         // (mid_end + hysteresis)^2 - leave MID (4 bytes, offset 40)
    float mid_enter_sq;        // (mid_end - hysteresis)^2 - enter MID (4 bytes, offset 44)
    float far_exit_sq;         // (far_end + hysteresis)^2 - leave FAR (4 bytes, offset 48)
    float far_enter_sq;        // (far_end - hysteresis)^2 - enter FAR (4 bytes, offset 52)

    // Padding to align uint to 16-byte boundary
    float _padding1;           // (4 bytes, offset 56)
    float _padding2;           // (4 bytes, offset 60)

    uint object_count;         // Total number of objects to process (4 bytes, offset 64)
    uint _pad1;                // Alignment padding (4 bytes, offset 68)
    uint _pad2;                // Alignment padding (4 bytes, offset 72)
    uint _pad3;                // Alignment padding (4 bytes, offset 76)
} pc;

// Tier constants matching DistanceTierManager.Tier enum
const uint TIER_NEAR = 0u;
const uint TIER_MID = 1u;
const uint TIER_FAR = 2u;
const uint TIER_HIDDEN = 3u;

// Calculate tier for an object using hysteresis
// prev_tier: The object's previous tier (for hysteresis)
// dist_sq: Squared distance from camera to object
// Returns: New tier assignment
uint calculate_tier_with_hysteresis(uint prev_tier, float dist_sq) {
    uint new_tier;

    // Apply hysteresis based on current tier
    // Objects need to move further to change tiers (prevents flickering)
    switch (prev_tier) {
        case TIER_NEAR:
            // Currently NEAR - use exit thresholds (harder to leave)
            if (dist_sq < pc.near_exit_sq) {
                new_tier = TIER_NEAR;
            } else if (dist_sq < pc.mid_exit_sq) {
                new_tier = TIER_MID;
            } else if (dist_sq < pc.far_exit_sq) {
                new_tier = TIER_FAR;
            } else {
                new_tier = TIER_HIDDEN;
            }
            break;

        case TIER_MID:
            // Currently MID - use enter threshold for NEAR, exit for FAR
            if (dist_sq < pc.near_enter_sq) {
                new_tier = TIER_NEAR;
            } else if (dist_sq < pc.mid_exit_sq) {
                new_tier = TIER_MID;
            } else if (dist_sq < pc.far_end_sq) {
                new_tier = TIER_FAR;
            } else {
                new_tier = TIER_HIDDEN;
            }
            break;

        case TIER_FAR:
            // Currently FAR - use enter thresholds for closer tiers
            if (dist_sq < pc.near_enter_sq) {
                new_tier = TIER_NEAR;
            } else if (dist_sq < pc.mid_enter_sq) {
                new_tier = TIER_MID;
            } else if (dist_sq < pc.far_exit_sq) {
                new_tier = TIER_FAR;
            } else {
                new_tier = TIER_HIDDEN;
            }
            break;

        default:
            // HIDDEN or uninitialized - use standard thresholds
            if (dist_sq < pc.near_end_sq) {
                new_tier = TIER_NEAR;
            } else if (dist_sq < pc.mid_end_sq) {
                new_tier = TIER_MID;
            } else if (dist_sq < pc.far_end_sq) {
                new_tier = TIER_FAR;
            } else {
                new_tier = TIER_HIDDEN;
            }
            break;
    }

    return new_tier;
}

void main() {
    // Get global invocation ID (object index)
    uint idx = gl_GlobalInvocationID.x;

    // Bounds check - skip if beyond object count
    if (idx >= pc.object_count) {
        return;
    }

    // Load object position
    vec4 obj_pos = positions[idx];

    // Calculate squared distance to camera (no sqrt needed)
    vec3 delta = obj_pos.xyz - pc.camera_pos.xyz;
    float dist_sq = dot(delta, delta);

    // Load previous tier for hysteresis
    uint prev_tier = prev_tiers[idx];

    // Calculate new tier with hysteresis
    uint new_tier = calculate_tier_with_hysteresis(prev_tier, dist_sq);

    // Write output - always write current tier
    curr_tiers[idx] = new_tier;

    // Check if tier changed
    bool did_change = (new_tier != prev_tier);

    // Legacy per-object change flag (backward compatibility)
    tier_changed[idx] = did_change ? 1u : 0u;

    // SPARSE READBACK: If tier changed, add to compact change buffer
    if (did_change) {
        // Atomically increment change counter and get our slot
        uint slot = atomicAdd(change_count, 1u);

        // Only write if we have room in the compact buffer
        if (slot < MAX_CHANGES) {
            // Write buffer index to compact list
            changed_indices[slot] = idx;

            // Pack change data: (index << 8) | (old_tier << 4) | new_tier
            // This allows CPU to reconstruct full change info without extra reads
            uint packed = (idx << 8u) | (prev_tier << 4u) | new_tier;
            changed_data[slot] = packed;
        }
        // Note: If slot >= MAX_CHANGES, the change is still in curr_tiers
        // but won't be in the sparse buffer. CPU falls back to full scan.
    }
}
