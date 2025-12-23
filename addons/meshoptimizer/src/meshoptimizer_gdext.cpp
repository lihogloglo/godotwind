// MeshOptimizer GDExtension for Godot 4
// Implementation wrapping meshoptimizer library

#include "meshoptimizer_gdext.h"
#include "../thirdparty/meshoptimizer.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <vector>
#include <cstring>

using namespace godot;

void MeshOptimizerGD::_bind_methods() {
    ClassDB::bind_method(D_METHOD("simplify", "vertices", "indices", "target_ratio", "target_error"),
        &MeshOptimizerGD::simplify, DEFVAL(0.01f));
    ClassDB::bind_method(D_METHOD("simplify_with_attributes", "vertices", "indices", "uvs", "target_ratio", "target_error", "uv_weight"),
        &MeshOptimizerGD::simplify_with_attributes, DEFVAL(0.01f), DEFVAL(1.0f));
    ClassDB::bind_method(D_METHOD("simplify_sloppy", "vertices", "indices", "target_ratio", "target_error"),
        &MeshOptimizerGD::simplify_sloppy, DEFVAL(0.01f));
    ClassDB::bind_method(D_METHOD("simplify_mesh_arrays", "mesh_arrays", "target_ratio", "target_error"),
        &MeshOptimizerGD::simplify_mesh_arrays, DEFVAL(0.01f));
    ClassDB::bind_method(D_METHOD("optimize_vertex_cache", "indices", "vertex_count"),
        &MeshOptimizerGD::optimize_vertex_cache);
    ClassDB::bind_method(D_METHOD("weld_vertices", "vertices", "indices", "threshold"),
        &MeshOptimizerGD::weld_vertices, DEFVAL(0.0001f));
    ClassDB::bind_method(D_METHOD("get_version"), &MeshOptimizerGD::get_version);
    ClassDB::bind_static_method("MeshOptimizerGD", D_METHOD("is_available"), &MeshOptimizerGD::is_available);
}

MeshOptimizerGD::MeshOptimizerGD() {}
MeshOptimizerGD::~MeshOptimizerGD() {}

Dictionary MeshOptimizerGD::simplify(
    PackedVector3Array vertices,
    PackedInt32Array indices,
    float target_ratio,
    float target_error
) {
    Dictionary result;

    if (vertices.size() == 0 || indices.size() == 0) {
        result["error"] = "Empty input";
        return result;
    }

    size_t vertex_count = vertices.size();
    size_t index_count = indices.size();
    size_t target_index_count = static_cast<size_t>(index_count * target_ratio);

    // Ensure minimum
    if (target_index_count < 3) target_index_count = 3;

    // Convert to raw arrays
    std::vector<float> vertex_data(vertex_count * 3);
    for (size_t i = 0; i < vertex_count; i++) {
        Vector3 v = vertices[i];
        vertex_data[i * 3 + 0] = v.x;
        vertex_data[i * 3 + 1] = v.y;
        vertex_data[i * 3 + 2] = v.z;
    }

    std::vector<unsigned int> index_data(index_count);
    for (size_t i = 0; i < index_count; i++) {
        index_data[i] = static_cast<unsigned int>(indices[i]);
    }

    // Output buffer
    std::vector<unsigned int> simplified_indices(index_count);
    float result_error = 0.0f;

    // Run simplification
    size_t new_index_count = meshopt_simplify(
        simplified_indices.data(),
        index_data.data(),
        index_count,
        vertex_data.data(),
        vertex_count,
        sizeof(float) * 3,
        target_index_count,
        target_error,
        0, // options
        &result_error
    );

    // Convert back to Godot types
    PackedInt32Array new_indices;
    new_indices.resize(new_index_count);
    for (size_t i = 0; i < new_index_count; i++) {
        new_indices[i] = static_cast<int32_t>(simplified_indices[i]);
    }

    result["indices"] = new_indices;
    result["vertices"] = vertices; // Vertices unchanged, just reindexed
    result["result_error"] = result_error;
    result["original_triangles"] = static_cast<int>(index_count / 3);
    result["simplified_triangles"] = static_cast<int>(new_index_count / 3);

    return result;
}

Dictionary MeshOptimizerGD::simplify_with_attributes(
    PackedVector3Array vertices,
    PackedInt32Array indices,
    PackedVector2Array uvs,
    float target_ratio,
    float target_error,
    float uv_weight
) {
    Dictionary result;

    if (vertices.size() == 0 || indices.size() == 0) {
        result["error"] = "Empty input";
        return result;
    }

    size_t vertex_count = vertices.size();
    size_t index_count = indices.size();
    size_t target_index_count = static_cast<size_t>(index_count * target_ratio);

    if (target_index_count < 3) target_index_count = 3;

    // Convert vertices
    std::vector<float> vertex_data(vertex_count * 3);
    for (size_t i = 0; i < vertex_count; i++) {
        Vector3 v = vertices[i];
        vertex_data[i * 3 + 0] = v.x;
        vertex_data[i * 3 + 1] = v.y;
        vertex_data[i * 3 + 2] = v.z;
    }

    std::vector<unsigned int> index_data(index_count);
    for (size_t i = 0; i < index_count; i++) {
        index_data[i] = static_cast<unsigned int>(indices[i]);
    }

    // Output buffer
    std::vector<unsigned int> simplified_indices(index_count);
    float result_error = 0.0f;

    // If UVs provided and match vertex count, use attribute-aware simplification
    if (uvs.size() == vertex_count) {
        // Prepare UV attributes
        std::vector<float> uv_data(vertex_count * 2);
        for (size_t i = 0; i < vertex_count; i++) {
            Vector2 uv = uvs[i];
            uv_data[i * 2 + 0] = uv.x;
            uv_data[i * 2 + 1] = uv.y;
        }

        float attribute_weights[1] = { uv_weight };

        size_t new_index_count = meshopt_simplifyWithAttributes(
            simplified_indices.data(),
            index_data.data(),
            index_count,
            vertex_data.data(),
            vertex_count,
            sizeof(float) * 3,
            uv_data.data(),
            sizeof(float) * 2,
            attribute_weights,
            1, // attribute count
            nullptr, // vertex lock (optional)
            target_index_count,
            target_error,
            0,
            &result_error
        );

        // Convert back
        PackedInt32Array new_indices;
        new_indices.resize(new_index_count);
        for (size_t i = 0; i < new_index_count; i++) {
            new_indices[i] = static_cast<int32_t>(simplified_indices[i]);
        }

        result["indices"] = new_indices;
        result["vertices"] = vertices;
        result["uvs"] = uvs;
        result["result_error"] = result_error;
        result["original_triangles"] = static_cast<int>(index_count / 3);
        result["simplified_triangles"] = static_cast<int>(new_index_count / 3);
    } else {
        // Fall back to regular simplification
        return simplify(vertices, indices, target_ratio, target_error);
    }

    return result;
}

Dictionary MeshOptimizerGD::simplify_sloppy(
    PackedVector3Array vertices,
    PackedInt32Array indices,
    float target_ratio,
    float target_error
) {
    Dictionary result;

    if (vertices.size() == 0 || indices.size() == 0) {
        result["error"] = "Empty input";
        return result;
    }

    size_t vertex_count = vertices.size();
    size_t index_count = indices.size();
    size_t target_index_count = static_cast<size_t>(index_count * target_ratio);

    if (target_index_count < 3) target_index_count = 3;

    // Convert to raw arrays
    std::vector<float> vertex_data(vertex_count * 3);
    for (size_t i = 0; i < vertex_count; i++) {
        Vector3 v = vertices[i];
        vertex_data[i * 3 + 0] = v.x;
        vertex_data[i * 3 + 1] = v.y;
        vertex_data[i * 3 + 2] = v.z;
    }

    std::vector<unsigned int> index_data(index_count);
    for (size_t i = 0; i < index_count; i++) {
        index_data[i] = static_cast<unsigned int>(indices[i]);
    }

    // Output buffer
    std::vector<unsigned int> simplified_indices(index_count);
    float result_error = 0.0f;

    // Run sloppy simplification (faster, ignores topology)
    size_t new_index_count = meshopt_simplifySloppy(
        simplified_indices.data(),
        index_data.data(),
        index_count,
        vertex_data.data(),
        vertex_count,
        sizeof(float) * 3,
        target_index_count,
        target_error,
        &result_error
    );

    // Convert back
    PackedInt32Array new_indices;
    new_indices.resize(new_index_count);
    for (size_t i = 0; i < new_index_count; i++) {
        new_indices[i] = static_cast<int32_t>(simplified_indices[i]);
    }

    result["indices"] = new_indices;
    result["vertices"] = vertices;
    result["result_error"] = result_error;
    result["original_triangles"] = static_cast<int>(index_count / 3);
    result["simplified_triangles"] = static_cast<int>(new_index_count / 3);

    return result;
}

Array MeshOptimizerGD::simplify_mesh_arrays(Array mesh_arrays, float target_ratio, float target_error) {
    Array result;

    if (mesh_arrays.size() < Mesh::ARRAY_MAX) {
        UtilityFunctions::push_error("MeshOptimizerGD: Invalid mesh arrays size");
        return result;
    }

    Variant v_vertices = mesh_arrays[Mesh::ARRAY_VERTEX];
    Variant v_indices = mesh_arrays[Mesh::ARRAY_INDEX];

    if (v_vertices.get_type() != Variant::PACKED_VECTOR3_ARRAY ||
        v_indices.get_type() != Variant::PACKED_INT32_ARRAY) {
        UtilityFunctions::push_error("MeshOptimizerGD: Missing vertices or indices");
        return result;
    }

    PackedVector3Array vertices = v_vertices;
    PackedInt32Array indices = v_indices;

    if (vertices.size() == 0 || indices.size() == 0) {
        return mesh_arrays; // Return original if empty
    }

    // Check for UVs
    PackedVector2Array uvs;
    Variant v_uvs = mesh_arrays[Mesh::ARRAY_TEX_UV];
    bool has_uvs = v_uvs.get_type() == Variant::PACKED_VECTOR2_ARRAY;
    if (has_uvs) {
        uvs = v_uvs;
    }

    // Simplify
    Dictionary simplified;
    if (has_uvs && uvs.size() == vertices.size()) {
        simplified = simplify_with_attributes(vertices, indices, uvs, target_ratio, target_error, 1.0f);
    } else {
        simplified = simplify(vertices, indices, target_ratio, target_error);
    }

    if (simplified.has("error")) {
        UtilityFunctions::push_warning("MeshOptimizerGD: ", simplified["error"]);
        return mesh_arrays;
    }

    // Build result arrays
    result.resize(Mesh::ARRAY_MAX);

    // Copy original vertices (simplification reuses them via indices)
    result[Mesh::ARRAY_VERTEX] = simplified["vertices"];
    result[Mesh::ARRAY_INDEX] = simplified["indices"];

    // Preserve other attributes from original
    if (has_uvs) {
        result[Mesh::ARRAY_TEX_UV] = mesh_arrays[Mesh::ARRAY_TEX_UV];
    }

    // Preserve normals if present
    Variant v_normals = mesh_arrays[Mesh::ARRAY_NORMAL];
    if (v_normals.get_type() == Variant::PACKED_VECTOR3_ARRAY) {
        result[Mesh::ARRAY_NORMAL] = v_normals;
    }

    // Preserve colors if present
    Variant v_colors = mesh_arrays[Mesh::ARRAY_COLOR];
    if (v_colors.get_type() == Variant::PACKED_COLOR_ARRAY) {
        result[Mesh::ARRAY_COLOR] = v_colors;
    }

    return result;
}

PackedInt32Array MeshOptimizerGD::optimize_vertex_cache(PackedInt32Array indices, int vertex_count) {
    if (indices.size() == 0 || vertex_count <= 0) {
        return indices;
    }

    size_t index_count = indices.size();
    std::vector<unsigned int> index_data(index_count);
    for (size_t i = 0; i < index_count; i++) {
        index_data[i] = static_cast<unsigned int>(indices[i]);
    }

    std::vector<unsigned int> optimized(index_count);
    meshopt_optimizeVertexCache(
        optimized.data(),
        index_data.data(),
        index_count,
        static_cast<size_t>(vertex_count)
    );

    PackedInt32Array result;
    result.resize(index_count);
    for (size_t i = 0; i < index_count; i++) {
        result[i] = static_cast<int32_t>(optimized[i]);
    }

    return result;
}

Dictionary MeshOptimizerGD::weld_vertices(
    PackedVector3Array vertices,
    PackedInt32Array indices,
    float threshold
) {
    Dictionary result;

    if (vertices.size() == 0) {
        result["error"] = "Empty vertices";
        return result;
    }

    size_t vertex_count = vertices.size();

    // Convert vertices
    std::vector<float> vertex_data(vertex_count * 3);
    for (size_t i = 0; i < vertex_count; i++) {
        Vector3 v = vertices[i];
        vertex_data[i * 3 + 0] = v.x;
        vertex_data[i * 3 + 1] = v.y;
        vertex_data[i * 3 + 2] = v.z;
    }

    // Generate remap table
    std::vector<unsigned int> remap(vertex_count);
    size_t unique_count = meshopt_generateVertexRemap(
        remap.data(),
        indices.size() > 0 ? reinterpret_cast<unsigned int*>(const_cast<int32_t*>(indices.ptr())) : nullptr,
        indices.size() > 0 ? indices.size() : vertex_count,
        vertex_data.data(),
        vertex_count,
        sizeof(float) * 3
    );

    // Apply remap to create new vertex buffer
    PackedVector3Array new_vertices;
    new_vertices.resize(unique_count);

    std::vector<float> remapped_vertices(unique_count * 3);
    meshopt_remapVertexBuffer(
        remapped_vertices.data(),
        vertex_data.data(),
        vertex_count,
        sizeof(float) * 3,
        remap.data()
    );

    for (size_t i = 0; i < unique_count; i++) {
        new_vertices[i] = Vector3(
            remapped_vertices[i * 3 + 0],
            remapped_vertices[i * 3 + 1],
            remapped_vertices[i * 3 + 2]
        );
    }

    // Remap indices if provided
    PackedInt32Array new_indices;
    if (indices.size() > 0) {
        new_indices.resize(indices.size());
        for (int i = 0; i < indices.size(); i++) {
            new_indices[i] = static_cast<int32_t>(remap[indices[i]]);
        }
    }

    result["vertices"] = new_vertices;
    result["indices"] = new_indices;
    result["original_count"] = static_cast<int>(vertex_count);
    result["unique_count"] = static_cast<int>(unique_count);

    return result;
}

String MeshOptimizerGD::get_version() {
    return String("meshoptimizer 0.21");
}

bool MeshOptimizerGD::is_available() {
    return true; // If this code runs, the library is available
}
