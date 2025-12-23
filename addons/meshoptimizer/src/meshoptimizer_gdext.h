// MeshOptimizer GDExtension for Godot 4
// Wraps meshoptimizer library for fast mesh simplification
#ifndef MESHOPTIMIZER_GDEXT_H
#define MESHOPTIMIZER_GDEXT_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class MeshOptimizerGD : public RefCounted {
    GDCLASS(MeshOptimizerGD, RefCounted)

protected:
    static void _bind_methods();

public:
    MeshOptimizerGD();
    ~MeshOptimizerGD();

    // Simplify mesh to target ratio (0.0-1.0)
    // Returns: Dictionary with "vertices", "indices", "uvs" (if present), "result_error"
    Dictionary simplify(
        PackedVector3Array vertices,
        PackedInt32Array indices,
        float target_ratio,
        float target_error = 0.01f
    );

    // Simplify mesh with UV preservation
    Dictionary simplify_with_attributes(
        PackedVector3Array vertices,
        PackedInt32Array indices,
        PackedVector2Array uvs,
        float target_ratio,
        float target_error = 0.01f,
        float uv_weight = 1.0f
    );

    // Sloppy simplification (faster, ignores topology)
    Dictionary simplify_sloppy(
        PackedVector3Array vertices,
        PackedInt32Array indices,
        float target_ratio,
        float target_error = 0.01f
    );

    // Simplify Godot mesh arrays directly
    // Input: Standard Godot mesh arrays (from surface_get_arrays)
    // Returns: Simplified mesh arrays ready for surface_add_arrays
    Array simplify_mesh_arrays(Array mesh_arrays, float target_ratio, float target_error = 0.01f);

    // Optimize vertex cache (improves GPU performance)
    PackedInt32Array optimize_vertex_cache(PackedInt32Array indices, int vertex_count);

    // Weld vertices (merge duplicates within threshold)
    Dictionary weld_vertices(
        PackedVector3Array vertices,
        PackedInt32Array indices,
        float threshold = 0.0001f
    );

    // Get library version
    String get_version();

    // Check if native library is available
    static bool is_available();
};

} // namespace godot

#endif // MESHOPTIMIZER_GDEXT_H
