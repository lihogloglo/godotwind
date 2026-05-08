shader_type particles;
render_mode disable_force;

#define MAX_CASCADES 8

global uniform uint num_cascades;
global uniform sampler2DArray displacements;
global uniform sampler2DArray normals : hint_normal;

uniform vec4 map_scales[MAX_CASCADES];
uniform sampler2D shore_mask : filter_linear_mipmap;
uniform vec4 shore_mask_bounds = vec4(-8000.0, -8000.0, 16000.0, 16000.0);

uniform bool spray_enabled = true;
uniform float sea_level = 0.0;
uniform float wave_scale = 1.0;
uniform float ocean_time = 0.0;
uniform vec3 camera_position = vec3(0.0);
uniform vec2 wind_direction = vec2(0.7071, 0.7071);
uniform float wind_strength = 0.0;
uniform float weather_energy = 0.0;

uniform uint grid_rows = 24u;
uniform float spray_window_size = 180.0;
uniform float spawn_near_fade = 10.0;
uniform float spawn_far_fade = 165.0;
uniform float crest_threshold = 0.42;
uniform float crest_softness = 0.24;
uniform float foam_spawn_threshold = 0.72;
uniform float min_particle_size = 0.45;
uniform float max_particle_size = 2.8;
uniform float size_variation = 0.62;
uniform float large_spray_chance = 0.09;
uniform float large_spray_multiplier = 1.75;
uniform float spray_lift = 0.18;
uniform float spray_opacity = 0.78;
uniform float spray_drift_speed = 9.0;
uniform float spray_updraft = 3.2;
uniform float spray_gravity = -3.6;
uniform float spray_surface_follow = 0.78;

float random(vec2 v) {
	return fract(sin(dot(v, vec2(12.9898, 78.233))) * 43758.5453123);
}

vec3 random3(vec2 v) {
	return vec3(
		random(v),
		random(v + vec2(19.17, 4.23)),
		random(v + vec2(7.91, 31.73))
	);
}

float shore_factor_at(vec2 world_xz) {
	vec2 shore_uv = (world_xz - shore_mask_bounds.xy) / shore_mask_bounds.zw;
	bool in_mask = shore_uv.x >= 0.0 && shore_uv.x <= 1.0 && shore_uv.y >= 0.0 && shore_uv.y <= 1.0;
	return in_mask ? textureLod(shore_mask, shore_uv, 0.0).r : 1.0;
}

float exp_impulse(float x, float k) {
	float h = k * x;
	return h * exp(1.0 - h);
}

vec4 sample_ocean_signal(vec2 world_xz) {
	vec3 displacement = vec3(0.0);
	vec3 gradient = vec3(0.0);
	float chop = 0.0;
	float dist = distance(vec3(world_xz.x, sea_level, world_xz.y), camera_position);
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		float tile_size = 1.0 / max(scales.x, 1e-6);
		float cascade_fade = clamp(exp(-(dist - 50.0) / (tile_size * 20.0)), 0.0, 1.0);
		vec3 cascade_disp = textureLod(displacements, vec3(world_xz * scales.xy, float(i)), 0.0).xyz * scales.z * cascade_fade;
		displacement += cascade_disp;
		chop += length(cascade_disp.xz);
		gradient += textureLod(normals, vec3(world_xz * scales.xy, float(i)), 0.0).xyw * vec3(scales.ww, 1.0) * cascade_fade;
	}
	float normal_y = inversesqrt(1.0 + dot(gradient.xy, gradient.xy));
	return vec4(displacement.y, chop, clamp(gradient.z, 0.0, 1.0), normal_y);
}

void start() {
	if (!spray_enabled || weather_energy <= 0.01 || num_cascades == 0U) {
		ACTIVE = false;
	} else {
		float row_count = float(max(grid_rows, 1u));
		float index = float(INDEX);
		vec2 cell = vec2(mod(index, row_count), floor(index / row_count));
		float cycle_seed = float(NUMBER & 4095u) * 0.0137 + ocean_time * 0.071;
		vec3 r = random3(cell + vec2(cycle_seed, cycle_seed * 1.37));
		vec2 cell_uv = (cell + r.xz) / row_count;
		vec2 candidate_xz = EMISSION_TRANSFORM[3].xz + (cell_uv - vec2(0.5)) * spray_window_size;

		float camera_dist = distance(candidate_xz, camera_position.xz);
		float distance_mask = smoothstep(0.0, spawn_near_fade, camera_dist)
			* (1.0 - smoothstep(spawn_far_fade * 0.82, spawn_far_fade, camera_dist));

		float shore = shore_factor_at(candidate_xz);
		vec4 wave = sample_ocean_signal(candidate_xz);
		float height = wave.x * wave_scale * shore;
		float chop = wave.y * wave_scale * shore;
		float foam = wave.z * shore;
		float normal_y = wave.w;
		float threshold = mix(crest_threshold + crest_softness * 0.55, crest_threshold, weather_energy);
		float crest_mask = smoothstep(threshold, threshold + crest_softness, chop);
		float height_mask = smoothstep(0.02, 0.55, height);
		float foam_mask = smoothstep(foam_spawn_threshold, 1.0, foam);
		float normal_mask = smoothstep(0.90, 0.985, normal_y);
		float energy = max(foam_mask * normal_mask, crest_mask * height_mask * 0.35) * weather_energy * distance_mask;

		if (energy <= 0.015) {
			ACTIVE = false;
		} else {
			float size_band = pow(r.y, 1.75);
			float size_jitter = mix(1.0 - size_variation, 1.0 + size_variation, size_band);
			float large_burst = mix(1.0, large_spray_multiplier, step(1.0 - large_spray_chance, r.x) * r.z);
			float base_size = mix(min_particle_size, max_particle_size, clamp(energy + r.y * 0.25, 0.0, 1.0));
			base_size *= size_jitter * large_burst;
			vec2 wind_dir = normalize(wind_direction + vec2(1e-4, 0.0));
			vec2 lateral = vec2(-wind_dir.y, wind_dir.x);
			vec2 side_drift = lateral * ((r.x - 0.5) * 2.0) * spray_drift_speed * 0.35;

			TRANSFORM = mat4(1.0);
			TRANSFORM[0] *= base_size;
			TRANSFORM[1] *= base_size;
			TRANSFORM[2] *= base_size;
			TRANSFORM[3].xyz = vec3(candidate_xz.x, sea_level + height + spray_lift, candidate_xz.y);

			float drift = spray_drift_speed * mix(0.28, 1.05, energy) * mix(0.55, 1.15, wind_strength);
			VELOCITY = vec3(
				wind_dir.x * drift + side_drift.x,
				spray_updraft * mix(0.45, 1.25, energy) + r.z * 0.8,
				wind_dir.y * drift + side_drift.y
			);

			CUSTOM = vec4(0.0, energy, base_size, r.x);
			COLOR = vec4(vec3(mix(0.72, 1.0, energy)), clamp(energy * spray_opacity, 0.0, 1.0));
		}
	}
}

void process() {
	if (!spray_enabled || weather_energy <= 0.01) {
		ACTIVE = false;
	} else {
		float age = clamp(CUSTOM.x + DELTA / max(LIFETIME, 0.001), 0.0, 1.0);
		CUSTOM.x = age;
		VELOCITY.y += spray_gravity * DELTA;

		vec2 current_xz = TRANSFORM[3].xz;
		float shore = shore_factor_at(current_xz);
		vec4 wave = sample_ocean_signal(current_xz);
		float surface_y = sea_level + wave.x * wave_scale * shore + spray_lift;
		float arc = exp_impulse(age, 3.2) * CUSTOM.y * 1.25;
		TRANSFORM[3].y = max(TRANSFORM[3].y, mix(TRANSFORM[3].y, surface_y + arc, spray_surface_follow));

		float width_aspect = mix(0.72, 1.38, random(vec2(CUSTOM.w, 17.31)));
		float height_aspect = mix(0.70, 1.62, random(vec2(CUSTOM.w, 41.79)));
		float width = CUSTOM.z * width_aspect * mix(0.70, 1.85, log(1.0 + age * 1.8));
		float height = CUSTOM.z * height_aspect * mix(0.45, 2.15, exp_impulse(age, 2.8));
		TRANSFORM[0] = vec4(width, 0.0, 0.0, 0.0);
		TRANSFORM[1] = vec4(0.0, height, 0.0, 0.0);
		TRANSFORM[2] = vec4(0.0, 0.0, width, 0.0);

		float birth_fade = smoothstep(0.0, 0.12, age);
		float death_fade = 1.0 - smoothstep(0.52, 1.0, age);
		float alpha = CUSTOM.y * spray_opacity * birth_fade * death_fade;
		COLOR = vec4(vec3(1.0), clamp(alpha, 0.0, 1.0));
	}
}
