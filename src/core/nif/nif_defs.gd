## NIF Definitions - Constants and types for NIF file parsing
## Ported from OpenMW components/nif/
class_name NIFDefs
extends RefCounted

# NIF Version constants (BCD format: major.minor.patch.rev)
const VER_MW: int = 0x04000002       # 4.0.0.2 - Morrowind
const VER_OB_OLD: int = 0x0A000102   # 10.0.1.2 - Older Oblivion
const VER_OB: int = 0x14000005       # 20.0.0.5 - Oblivion
const VER_BGS: int = 0x14020007      # 20.2.0.7 - Bethesda games (FO3, Skyrim)

# Record type names (strings as stored in Morrowind NIF files)
# Nodes
const RT_NI_NODE := "NiNode"
const RT_ROOT_COLLISION_NODE := "RootCollisionNode"
const RT_NI_BILLBOARD_NODE := "NiBillboardNode"
const RT_AVOID_NODE := "AvoidNode"
const RT_NI_BS_ANIMATION_NODE := "NiBSAnimationNode"
const RT_NI_BS_PARTICLE_NODE := "NiBSParticleNode"
const RT_NI_COLLISION_SWITCH := "NiCollisionSwitch"
const RT_NI_SORT_ADJUST_NODE := "NiSortAdjustNode"
const RT_NI_SWITCH_NODE := "NiSwitchNode"
const RT_NI_LOD_NODE := "NiLODNode"
const RT_NI_FLT_ANIMATION_NODE := "NiFltAnimationNode"

# Geometry
const RT_NI_TRI_SHAPE := "NiTriShape"
const RT_NI_TRI_STRIPS := "NiTriStrips"
const RT_NI_TRI_SHAPE_DATA := "NiTriShapeData"
const RT_NI_TRI_STRIPS_DATA := "NiTriStripsData"
const RT_NI_LINES := "NiLines"
const RT_NI_LINES_DATA := "NiLinesData"

# Properties
const RT_NI_TEXTURING_PROPERTY := "NiTexturingProperty"
const RT_NI_MATERIAL_PROPERTY := "NiMaterialProperty"
const RT_NI_ALPHA_PROPERTY := "NiAlphaProperty"
const RT_NI_SOURCE_TEXTURE := "NiSourceTexture"
const RT_NI_VERTEX_COLOR_PROPERTY := "NiVertexColorProperty"
const RT_NI_ZBUFFER_PROPERTY := "NiZBufferProperty"
const RT_NI_SPECULAR_PROPERTY := "NiSpecularProperty"
const RT_NI_WIREFRAME_PROPERTY := "NiWireframeProperty"
const RT_NI_STENCIL_PROPERTY := "NiStencilProperty"
const RT_NI_SHADE_PROPERTY := "NiShadeProperty"
const RT_NI_DITHER_PROPERTY := "NiDitherProperty"
const RT_NI_FOG_PROPERTY := "NiFogProperty"

# Skinning
const RT_NI_SKIN_INSTANCE := "NiSkinInstance"
const RT_NI_SKIN_DATA := "NiSkinData"
const RT_NI_SKIN_PARTITION := "NiSkinPartition"

# Controllers
const RT_NI_KEYFRAME_CONTROLLER := "NiKeyframeController"
const RT_NI_KEYFRAME_DATA := "NiKeyframeData"
const RT_NI_VIS_CONTROLLER := "NiVisController"
const RT_NI_VIS_DATA := "NiVisData"
const RT_NI_UV_CONTROLLER := "NiUVController"
const RT_NI_UV_DATA := "NiUVData"
const RT_NI_GEOM_MORPHER_CONTROLLER := "NiGeomMorpherController"
const RT_NI_MORPH_DATA := "NiMorphData"
const RT_NI_FLIP_CONTROLLER := "NiFlipController"
const RT_NI_ALPHA_CONTROLLER := "NiAlphaController"
const RT_NI_FLOAT_DATA := "NiFloatData"
const RT_NI_MATERIAL_COLOR_CONTROLLER := "NiMaterialColorController"
const RT_NI_PATH_CONTROLLER := "NiPathController"
const RT_NI_POS_DATA := "NiPosData"
const RT_NI_ROLL_CONTROLLER := "NiRollController"
const RT_NI_LOOK_AT_CONTROLLER := "NiLookAtController"
const RT_NI_LIGHT_COLOR_CONTROLLER := "NiLightColorController"
const RT_NI_COLOR_DATA := "NiColorData"

# Particle System Controllers
const RT_NI_PARTICLE_SYSTEM_CONTROLLER := "NiParticleSystemController"
const RT_NI_BSP_ARRAY_CONTROLLER := "NiBSPArrayController"

# Lights
const RT_NI_POINT_LIGHT := "NiPointLight"
const RT_NI_SPOT_LIGHT := "NiSpotLight"
const RT_NI_DIRECTIONAL_LIGHT := "NiDirectionalLight"
const RT_NI_AMBIENT_LIGHT := "NiAmbientLight"

# Particles
const RT_NI_AUTO_NORMAL_PARTICLES := "NiAutoNormalParticles"
const RT_NI_ROTATE_PARTICLES := "NiRotatingParticles"
const RT_NI_AUTO_NORMAL_PARTICLES_DATA := "NiAutoNormalParticlesData"
const RT_NI_ROTATE_PARTICLES_DATA := "NiRotatingParticlesData"
const RT_NI_PARTICLES := "NiParticles"
const RT_NI_PARTICLES_DATA := "NiParticlesData"

# Particle Modifiers
const RT_NI_GRAVITY := "NiGravity"
const RT_NI_PARTICLE_GROW_FADE := "NiParticleGrowFade"
const RT_NI_PARTICLE_COLOR_MODIFIER := "NiParticleColorModifier"
const RT_NI_PARTICLE_ROTATION := "NiParticleRotation"
const RT_NI_PARTICLE_BOMB := "NiParticleBomb"

# Colliders
const RT_NI_PLANAR_COLLIDER := "NiPlanarCollider"
const RT_NI_SPHERICAL_COLLIDER := "NiSphericalCollider"

# Extra Data
const RT_NI_STRING_EXTRA_DATA := "NiStringExtraData"
const RT_NI_TEXT_KEY_EXTRA_DATA := "NiTextKeyExtraData"
const RT_NI_EXTRA_DATA := "NiExtraData"
const RT_NI_VERT_WEIGHTS_EXTRA_DATA := "NiVertWeightsExtraData"
# Additional Extra Data types (use generic reader - they all have bytes_remaining field)
const RT_NI_BINARY_EXTRA_DATA := "NiBinaryExtraData"
const RT_NI_BOOLEAN_EXTRA_DATA := "NiBooleanExtraData"
const RT_NI_COLOR_EXTRA_DATA := "NiColorExtraData"
const RT_NI_FLOAT_EXTRA_DATA := "NiFloatExtraData"
const RT_NI_FLOATS_EXTRA_DATA := "NiFloatsExtraData"
const RT_NI_INTEGER_EXTRA_DATA := "NiIntegerExtraData"
const RT_NI_INTEGERS_EXTRA_DATA := "NiIntegersExtraData"
const RT_NI_VECTOR_EXTRA_DATA := "NiVectorExtraData"
const RT_NI_STRINGS_EXTRA_DATA := "NiStringsExtraData"

# Other
const RT_NI_CAMERA := "NiCamera"
const RT_NI_TEXTURE_EFFECT := "NiTextureEffect"
const RT_NI_PIXEL_DATA := "NiPixelData"
const RT_NI_PALETTE := "NiPalette"
const RT_NI_RANGE_LOD_DATA := "NiRangeLODData"
const RT_NI_SCREEN_LOD_DATA := "NiScreenLODData"
const RT_NI_SEQUENCE_STREAM_HELPER := "NiSequenceStreamHelper"

# Accumulators
const RT_NI_ALPHA_ACCUMULATOR := "NiAlphaAccumulator"
const RT_NI_CLUSTER_ACCUMULATOR := "NiClusterAccumulator"

# NiAVObject flags
const FLAG_HIDDEN: int = 0x0001
const FLAG_MESH_COLLISION: int = 0x0002
const FLAG_BBOX_COLLISION: int = 0x0004
const FLAG_ACTIVE_COLLISION: int = 0x0020

# Bounding volume types
const BV_BASE: int = 0xFFFFFFFF  # No bounds (-1 cast to uint)
const BV_SPHERE: int = 0
const BV_BOX: int = 1
const BV_CAPSULE: int = 2
const BV_LOZENGE: int = 3
const BV_UNION: int = 4
const BV_HALFSPACE: int = 5

# Texture types (NiTexturingProperty)
enum TextureType {
	BASE = 0,
	DARK = 1,
	DETAIL = 2,
	GLOSS = 3,
	GLOW = 4,
	BUMP = 5,
	DECAL = 6
}

# Apply modes (NiTexturingProperty)
enum ApplyMode {
	REPLACE = 0,
	DECAL = 1,
	MODULATE = 2,
	HILIGHT = 3,
	HILIGHT2 = 4
}

# Interpolation types for animation keys
enum InterpolationType {
	UNKNOWN = 0,
	LINEAR = 1,
	QUADRATIC = 2,
	TCB = 3,  # Tension/Continuity/Bias
	XYZ = 4,
	CONSTANT = 5
}

# NiGeometryData flags
const DATA_FLAG_HAS_UV: int = 0x0001
const DATA_FLAG_NUM_UVS_MASK: int = 0x003F
const DATA_FLAG_HAS_TANGENTS: int = 0x1000

# Alpha property flags
const ALPHA_BLEND_ENABLE: int = 0x0001
const ALPHA_TEST_ENABLE: int = 0x0200

# Z-buffer property flags
const ZBUF_TEST: int = 0x0001
const ZBUF_WRITE: int = 0x0002

## Simple 3D transform (position, rotation, scale)
class NIFTransform:
	var translation: Vector3 = Vector3.ZERO
	var rotation: Basis = Basis.IDENTITY
	var scale: float = 1.0

	func to_transform3d() -> Transform3D:
		return Transform3D(rotation * scale, translation)

## Bounding sphere (used in BoundingVolume)
class BoundingSphere:
	var center: Vector3 = Vector3.ZERO
	var radius: float = 0.0

## Bounding box with orientation axes (used in BoundingVolume)
class BoundingBox:
	var center: Vector3 = Vector3.ZERO
	var axes: Basis = Basis.IDENTITY  # 3x3 matrix of orientation axes
	var extents: Vector3 = Vector3.ONE  # Half-extents along each axis

## Bounding capsule (used in BoundingVolume)
class BoundingCapsule:
	var center: Vector3 = Vector3.ZERO
	var axis: Vector3 = Vector3.UP
	var extent: float = 0.0  # Half-length along axis
	var radius: float = 0.0

## Bounding lozenge - like a capsule with flat ends (rare)
class BoundingLozenge:
	var center: Vector3 = Vector3.ZERO
	var axis0: Vector3 = Vector3.RIGHT
	var axis1: Vector3 = Vector3.FORWARD
	var radius: float = 0.0
	var extent0: float = 0.0
	var extent1: float = 0.0

## Bounding half-space (plane)
class BoundingHalfSpace:
	var plane: Plane = Plane()
	var origin: Vector3 = Vector3.ZERO

## BoundingVolume - represents various collision primitives in NIF files
## Morrowind uses these for basic collision detection
class BoundingVolume:
	var type: int = BV_BASE  # One of the BV_* constants
	var sphere: BoundingSphere = null
	var box: BoundingBox = null
	var capsule: BoundingCapsule = null
	var lozenge: BoundingLozenge = null
	var half_space: BoundingHalfSpace = null
	var children: Array = []  # For UNION_BV type, array of child BoundingVolumes

	func is_valid() -> bool:
		return type != BV_BASE

## Base record class - all NIF records inherit from this
class NIFRecord:
	var record_type: String = ""
	var record_index: int = -1
	var is_valid: bool = true  # Set to false for unknown/unparseable records

	func _to_string() -> String:
		return "[%d] %s" % [record_index, record_type]

## NiObjectNET - named object with extra data and controller
class NiObjectNET extends NIFRecord:
	var name: String = ""
	var extra_data_index: int = -1
	var controller_index: int = -1

## NiAVObject - scene graph object with transform
class NiAVObject extends NiObjectNET:
	var flags: int = 0
	var transform: NIFTransform = NIFTransform.new()
	var velocity: Vector3 = Vector3.ZERO
	var property_indices: Array[int] = []
	var has_bounding_volume: bool = false
	var bounding_volume: BoundingVolume = null  # Full bounding volume data
	var bounding_sphere: BoundingSphere = BoundingSphere.new()  # Kept for backward compat

	func is_hidden() -> bool:
		return (flags & FLAG_HIDDEN) != 0

	func has_mesh_collision() -> bool:
		return (flags & FLAG_MESH_COLLISION) != 0

	func has_bbox_collision() -> bool:
		return (flags & FLAG_BBOX_COLLISION) != 0

	func collision_active() -> bool:
		return (flags & FLAG_ACTIVE_COLLISION) != 0

## NiNode - parent node with children
class NiNode extends NiAVObject:
	var children_indices: Array[int] = []
	var effects_indices: Array[int] = []

## NiGeometry - base geometry class
class NiGeometry extends NiAVObject:
	var data_index: int = -1
	var skin_index: int = -1
	var material_names: Array[String] = []

## NiTriShape - triangle mesh geometry
class NiTriShape extends NiGeometry:
	pass

## NiTriStrips - triangle strip geometry
class NiTriStrips extends NiGeometry:
	pass

## NiLines - line geometry
class NiLines extends NiGeometry:
	pass

## NiGeometryData - geometry data (vertices, normals, etc.)
class NiGeometryData extends NIFRecord:
	var num_vertices: int = 0
	var vertices: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var tangents: PackedVector3Array = PackedVector3Array()
	var bitangents: PackedVector3Array = PackedVector3Array()
	var colors: PackedColorArray = PackedColorArray()
	var uv_sets: Array[PackedVector2Array] = []
	var center: Vector3 = Vector3.ZERO
	var radius: float = 0.0
	var data_flags: int = 0

	func get_num_uv_sets() -> int:
		return data_flags & DATA_FLAG_NUM_UVS_MASK

## NiTriShapeData - triangle mesh data
class NiTriShapeData extends NiGeometryData:
	var num_triangles: int = 0
	var triangles: PackedInt32Array = PackedInt32Array()  # Indices (3 per triangle)

## NiTriStripsData - triangle strip data
class NiTriStripsData extends NiGeometryData:
	var num_triangles: int = 0
	var strips: Array[PackedInt32Array] = []  # Each strip is a list of indices

## NiLinesData - line geometry data
class NiLinesData extends NiGeometryData:
	var lines: PackedInt32Array = PackedInt32Array()  # Line indices (pairs of vertices)

## NiPixelFormat - pixel format description for internal textures
class NiPixelFormat:
	var format: int = 0  # 0=RGB, 1=RGBA, 2=Palette, 3=PaletteAlpha, 4=BGR, 5=BGRA, 6=DXT1, 7=DXT3, 8=DXT5
	var color_masks: PackedInt32Array = PackedInt32Array([0, 0, 0, 0])  # RGBA masks
	var bits_per_pixel: int = 0
	var compare_bits: PackedInt32Array = PackedInt32Array([0, 0])

## NiPixelData - internal texture data
class NiPixelData extends NIFRecord:
	var pixel_format: NiPixelFormat = NiPixelFormat.new()
	var palette_index: int = -1
	var bytes_per_pixel: int = 0
	var mipmaps: Array[Dictionary] = []  # Array of {width, height, offset}
	var num_faces: int = 1
	var pixel_data: PackedByteArray = PackedByteArray()

## NiPalette - color palette for paletted textures
class NiPalette extends NIFRecord:
	var has_alpha: bool = false
	var colors: PackedColorArray = PackedColorArray()  # 256 color entries

## NiSkinPartition - optimized skin partition data
class NiSkinPartition extends NIFRecord:
	var partitions: Array[Dictionary] = []  # Array of partition data

## NiProperty - base property class
class NiProperty extends NiObjectNET:
	pass

## Texture descriptor
class TextureDesc:
	var has_texture: bool = false
	var source_index: int = -1
	var clamp_mode: int = 0
	var filter_mode: int = 0
	var uv_set: int = 0

## NiTexturingProperty - texturing info
class NiTexturingProperty extends NiProperty:
	var flags: int = 0
	var apply_mode: int = ApplyMode.MODULATE
	var textures: Array[TextureDesc] = []
	var env_map_luma_bias: Vector2 = Vector2.ZERO
	var bump_map_matrix: Array[float] = [1.0, 0.0, 0.0, 1.0]

## NiMaterialProperty - material colors
class NiMaterialProperty extends NiProperty:
	var flags: int = 0
	var ambient: Color = Color(1, 1, 1, 1)
	var diffuse: Color = Color(1, 1, 1, 1)
	var specular: Color = Color(0, 0, 0, 1)
	var emissive: Color = Color(0, 0, 0, 1)
	var glossiness: float = 0.0
	var alpha: float = 1.0

## NiAlphaProperty - transparency settings
class NiAlphaProperty extends NiProperty:
	var alpha_flags: int = 0
	var threshold: int = 0

	func blend_enabled() -> bool:
		return (alpha_flags & ALPHA_BLEND_ENABLE) != 0

	func test_enabled() -> bool:
		return (alpha_flags & ALPHA_TEST_ENABLE) != 0

## NiVertexColorProperty - vertex color mode
class NiVertexColorProperty extends NiProperty:
	var flags: int = 0
	var vertex_mode: int = 0
	var lighting_mode: int = 0

## NiZBufferProperty - z-buffer settings
class NiZBufferProperty extends NiProperty:
	var zbuf_flags: int = ZBUF_TEST | ZBUF_WRITE

	func test_enabled() -> bool:
		return (zbuf_flags & ZBUF_TEST) != 0

	func write_enabled() -> bool:
		return (zbuf_flags & ZBUF_WRITE) != 0

## NiSpecularProperty - specular enable flag
class NiSpecularProperty extends NiProperty:
	var enabled: bool = false

## NiWireframeProperty - wireframe enable flag
class NiWireframeProperty extends NiProperty:
	var enabled: bool = false

## NiStencilProperty - stencil buffer settings
class NiStencilProperty extends NiProperty:
	var flags: int = 0
	var enabled: bool = false
	var test_function: int = 0
	var stencil_ref: int = 0
	var stencil_mask: int = 0xFFFFFFFF
	var fail_action: int = 0
	var z_fail_action: int = 0
	var pass_action: int = 0
	var draw_mode: int = 0

## NiDitherProperty - dithering enable flag
class NiDitherProperty extends NiProperty:
	var flags: int = 0

## NiFogProperty - fog settings
class NiFogProperty extends NiProperty:
	var flags: int = 0
	var fog_depth: float = 0.0
	var fog_color: Color = Color.WHITE

## NiShadeProperty - shade mode settings
class NiShadeProperty extends NiProperty:
	var flags: int = 0

## NiSourceTexture - texture source/file reference
class NiSourceTexture extends NiObjectNET:
	var is_external: bool = true
	var filename: String = ""
	var pixel_layout: int = 0
	var use_mipmaps: int = 0
	var alpha_format: int = 0
	var is_static: bool = true
	var internal_data_index: int = -1

## NiStringExtraData - string metadata
class NiStringExtraData extends NIFRecord:
	var next_extra_data_index: int = -1
	var string_data: String = ""

## NiTextKeyExtraData - animation text keys
class NiTextKeyExtraData extends NIFRecord:
	var next_extra_data_index: int = -1
	var keys: Array[Dictionary] = []  # Array of {time: float, value: String}

## NiExtraData - base extra data
class NiExtraData extends NIFRecord:
	var next_extra_data_index: int = -1
	var bytes_remaining: int = 0

## NiVertWeightsExtraData - vertex weights extra data
class NiVertWeightsExtraData extends NIFRecord:
	var next_extra_data_index: int = -1
	var num_bytes: int = 0
	var num_vertices: int = 0
	var weights: PackedFloat32Array = PackedFloat32Array()

## NiTimeController - base controller class
class NiTimeController extends NIFRecord:
	var next_controller_index: int = -1
	var flags: int = 0
	var frequency: float = 1.0
	var phase: float = 0.0
	var start_time: float = 0.0
	var stop_time: float = 0.0
	var target_index: int = -1

## NiKeyframeController - transform animation controller
class NiKeyframeController extends NiTimeController:
	var data_index: int = -1

## NiKeyframeData - keyframe animation data
class NiKeyframeData extends NIFRecord:
	var rotation_type: int = 0
	var rotation_keys: Array = []
	# XYZ rotation keys - used when rotation_type == InterpolationType.XYZ
	# Contains separate key arrays for each axis (x_keys, y_keys, z_keys)
	# Each array contains keys with {time: float, value: float, ...}
	var x_rotation_keys: Array = []
	var y_rotation_keys: Array = []
	var z_rotation_keys: Array = []
	var translation_type: int = 0
	var translation_keys: Array = []
	var scale_type: int = 0
	var scale_keys: Array = []

## NiVisController - visibility animation controller
class NiVisController extends NiTimeController:
	var data_index: int = -1

## NiVisData - visibility animation data
class NiVisData extends NIFRecord:
	var keys: Array[Dictionary] = []  # Array of {time: float, visible: bool}

## NiUVController - UV animation controller
class NiUVController extends NiTimeController:
	var uv_set: int = 0
	var data_index: int = -1

## NiUVData - UV animation data
class NiUVData extends NIFRecord:
	var u_translation_keys: Array = []
	var v_translation_keys: Array = []
	var u_scale_keys: Array = []
	var v_scale_keys: Array = []

## NiAlphaController - alpha animation controller
class NiAlphaController extends NiTimeController:
	var data_index: int = -1

## NiMaterialColorController - material color animation
class NiMaterialColorController extends NiTimeController:
	var target_color: int = 0  # 0=ambient, 1=diffuse, 2=specular, 3=emissive
	var data_index: int = -1

## NiFlipController - texture flipbook animation
class NiFlipController extends NiTimeController:
	var texture_slot: int = 0
	var delta: float = 0.0
	var source_indices: Array[int] = []

## NiFloatData - float keyframe data
class NiFloatData extends NIFRecord:
	var key_type: int = 0
	var keys: Array = []

## NiColorData - color keyframe data
class NiColorData extends NIFRecord:
	var key_type: int = 0
	var keys: Array = []

## NiPosData - position keyframe data
class NiPosData extends NIFRecord:
	var key_type: int = 0
	var keys: Array = []

## NiMorphData - morph target data
class NiMorphData extends NIFRecord:
	var num_morphs: int = 0
	var num_vertices: int = 0
	var relative_targets: int = 0
	var morphs: Array = []

## NiGeomMorpherController - morph animation controller
class NiGeomMorpherController extends NiTimeController:
	var data_index: int = -1
	var always_update: bool = false

## NiPathController - path animation controller
class NiPathController extends NiTimeController:
	var path_flags: int = 0
	var bank_direction: int = 0
	var max_bank_angle: float = 0.0
	var smoothing: float = 0.0
	var follow_axis: int = 0
	var path_data_index: int = -1
	var percent_data_index: int = -1

## NiLookAtController - look-at controller
class NiLookAtController extends NiTimeController:
	var look_at_index: int = -1

## NiRollController - roll controller
class NiRollController extends NiTimeController:
	var data_index: int = -1

## NiLight - base light class
class NiLight extends NiAVObject:
	var dimmer: float = 1.0
	var ambient_color: Color = Color.BLACK
	var diffuse_color: Color = Color.WHITE
	var specular_color: Color = Color.BLACK

## NiPointLight - point light
class NiPointLight extends NiLight:
	var constant_atten: float = 0.0
	var linear_atten: float = 0.0
	var quadratic_atten: float = 0.0

## NiSpotLight - spot light
class NiSpotLight extends NiPointLight:
	var outer_spot_angle: float = 0.0
	var inner_spot_angle: float = 0.0
	var exponent: float = 1.0

## NiCamera - camera node
class NiCamera extends NiAVObject:
	var frustum_left: float = 0.0
	var frustum_right: float = 0.0
	var frustum_top: float = 0.0
	var frustum_bottom: float = 0.0
	var frustum_near: float = 0.0
	var frustum_far: float = 0.0
	var viewport_left: float = 0.0
	var viewport_right: float = 1.0
	var viewport_top: float = 1.0
	var viewport_bottom: float = 0.0
	var lod_adjust: float = 0.0

## NiTextureEffect - environment map effect
class NiTextureEffect extends NiAVObject:
	var model_projection_matrix: Basis = Basis.IDENTITY
	var model_projection_translation: Vector3 = Vector3.ZERO
	var texture_filtering: int = 0
	var texture_clamping: int = 0
	var texture_type: int = 0
	var coord_gen_type: int = 0
	var source_texture_index: int = -1
	var clipping_plane_enable: bool = false
	var clipping_plane: Plane = Plane()

## NiParticles - base particle system geometry
class NiParticles extends NiGeometry:
	pass

## NiParticlesData - particle system data
class NiParticlesData extends NiGeometryData:
	var num_particles: int = 0
	var particle_radius: float = 0.0
	var num_active: int = 0
	var has_sizes: bool = false
	var sizes: PackedFloat32Array = PackedFloat32Array()

## NiParticleSystemController - particle system controller
class NiParticleSystemController extends NiTimeController:
	var speed: float = 0.0
	var speed_variation: float = 0.0
	var declination: float = 0.0
	var declination_variation: float = 0.0
	var planar_angle: float = 0.0
	var planar_angle_variation: float = 0.0
	var initial_normal: Vector3 = Vector3.UP
	var initial_color: Color = Color.WHITE
	var initial_size: float = 1.0
	var emit_start_time: float = 0.0
	var emit_stop_time: float = 0.0
	var emit_flags: int = 0
	var emitter_dimensions: Vector3 = Vector3.ZERO
	var emitter_index: int = -1
	var birth_rate: float = 0.0
	var lifetime: float = 0.0
	var lifetime_variation: float = 0.0

## NiGravity - gravity particle modifier
class NiGravity extends NIFRecord:
	var decay: float = 0.0
	var force: float = 0.0
	var gravity_type: int = 0
	var position: Vector3 = Vector3.ZERO
	var direction: Vector3 = Vector3.DOWN

## NiParticleGrowFade - particle grow/fade modifier
class NiParticleGrowFade extends NIFRecord:
	var grow_time: float = 0.0
	var fade_time: float = 0.0

## NiParticleColorModifier - particle color modifier
class NiParticleColorModifier extends NIFRecord:
	var color_data_index: int = -1

## NiParticleRotation - particle rotation modifier
class NiParticleRotation extends NIFRecord:
	var random_initial_axis: bool = false
	var initial_axis: Vector3 = Vector3.UP
	var rotation_speed: float = 0.0

## NiPlanarCollider - planar collision for particles
class NiPlanarCollider extends NIFRecord:
	var bounce: float = 0.0
	var plane_normal: Vector3 = Vector3.UP
	var plane_distance: float = 0.0

## NiSphericalCollider - spherical collision for particles
class NiSphericalCollider extends NIFRecord:
	var bounce: float = 0.0
	var radius: float = 0.0
	var center: Vector3 = Vector3.ZERO

## NiSkinInstance - skinning instance
class NiSkinInstance extends NIFRecord:
	var data_index: int = -1
	var root_index: int = -1
	var bone_indices: Array[int] = []

## NiSkinData - skinning data
class NiSkinData extends NIFRecord:
	var skin_transform: NIFTransform = NIFTransform.new()
	var partition_index: int = -1  # Reference to NiSkinPartition (Morrowind)
	var bones: Array = []  # Array of bone info dictionaries

## NiRangeLODData - LOD range data
class NiRangeLODData extends NIFRecord:
	var lod_center: Vector3 = Vector3.ZERO
	var lod_levels: Array = []  # Array of {min_range: float, max_range: float}

## NiLODNode - LOD node
class NiLODNode extends NiNode:
	var lod_center: Vector3 = Vector3.ZERO
	var lod_levels: Array = []

## NiSwitchNode - switch node
class NiSwitchNode extends NiNode:
	var switch_flags: int = 0
	var initial_index: int = 0

## Helper to parse NIF version from header string
static func parse_version_string(header: String) -> int:
	# Header format: "NetImmerse File Format, Version X.X.X.X"
	# or "Gamebryo File Format, Version X.X.X.X"
	var version_pos := header.find("Version ")
	if version_pos == -1:
		return 0

	var version_str := header.substr(version_pos + 8).strip_edges()
	var parts := version_str.split(".")
	if parts.size() != 4:
		return 0

	var major := parts[0].to_int()
	var minor := parts[1].to_int()
	var patch := parts[2].to_int()
	var rev := parts[3].to_int()

	return (major << 24) | (minor << 16) | (patch << 8) | rev

## Generate version int from components
static func make_version(major: int, minor: int, patch: int, rev: int) -> int:
	return (major << 24) | (minor << 16) | (patch << 8) | rev

## Get version string from int
static func version_to_string(version: int) -> String:
	var major := (version >> 24) & 0xFF
	var minor := (version >> 16) & 0xFF
	var patch := (version >> 8) & 0xFF
	var rev := version & 0xFF
	return "%d.%d.%d.%d" % [major, minor, patch, rev]

## Check if this is a Morrowind NIF version
static func is_morrowind_version(version: int) -> bool:
	return version == VER_MW
