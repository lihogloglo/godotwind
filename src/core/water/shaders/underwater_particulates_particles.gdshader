shader_type particles;
render_mode disable_force;

uniform bool particles_enabled = true;
uniform float sea_level = 0.0;
uniform vec3 camera_position = vec3(0.0);
uniform vec3 spawn_center = vec3(0.0);
uniform float camera_water_depth = 0.0;
uniform vec2 current_direction = vec2(0.9285, 0.3714);
uniform float current_strength = 0.35;
uniform float window_radius_m = 8.0;
uniform float vertical_half_extent_m = 3.0;
uniform float mote_min_size_m = 0.005;
uniform float mote_max_size_m = 0.010;
uniform float mote_opacity = 0.75;
uniform float mote_size_scale = 1.0;
uniform float drift_speed_scale = 1.0;

float random(vec2 v) {
	return fract(sin(dot(v, vec2(12.9898, 78.233))) * 43758.5453123);
}

vec3 random3(vec2 v) {
	return vec3(
		random(v),
		random(v + vec2(17.17, 3.31)),
		random(v + vec2(5.79, 29.47))
	);
}

void start() {
	if (!particles_enabled || camera_water_depth <= 0.05) {
		ACTIVE = false;
	} else {
		float seed = float(INDEX) * 0.0173 + float(NUMBER & 4095u) * 0.113;
		vec3 r = random3(vec2(seed, seed * 1.73));
		float angle = r.x * 6.2831853;
		float radius = sqrt(r.y) * window_radius_m;
		vec2 xz_offset = vec2(cos(angle), sin(angle)) * radius;
		float y_offset = (r.z * 2.0 - 1.0) * vertical_half_extent_m;
		float spawn_y = min(spawn_center.y + y_offset, sea_level - 0.035);
		spawn_y = max(spawn_y, camera_position.y - vertical_half_extent_m);

		float size = mix(mote_min_size_m, mote_max_size_m, random(vec2(seed, 41.7))) * mote_size_scale;
		float alpha = mote_opacity * mix(0.35, 1.0, random(vec2(seed, 83.1)));
		vec2 current = normalize(current_direction + vec2(0.0001, -0.0001));
		vec2 lateral = vec2(-current.y, current.x);
		float drift_speed = mix(0.08, 0.34, clamp(current_strength, 0.0, 1.0)) * drift_speed_scale;
		float lateral_speed = (random(vec2(seed, 121.9)) - 0.5) * 0.11 * drift_speed_scale;
		float vertical_speed = (random(vec2(seed, 211.4)) - 0.5) * 0.045 * drift_speed_scale;

		TRANSFORM = mat4(1.0);
		TRANSFORM[0] *= size;
		TRANSFORM[1] *= size;
		TRANSFORM[2] *= size;
		TRANSFORM[3].xyz = vec3(spawn_center.x + xz_offset.x, spawn_y, spawn_center.z + xz_offset.y);

		VELOCITY = vec3(
			current.x * drift_speed + lateral.x * lateral_speed,
			vertical_speed,
			current.y * drift_speed + lateral.y * lateral_speed
		);
		CUSTOM = vec4(0.0, size, alpha, seed);
		COLOR = vec4(vec3(0.86, 0.96, 0.94), alpha);
	}
}

void process() {
	float camera_distance_xz = distance(TRANSFORM[3].xz, camera_position.xz);
	bool outside_window = camera_distance_xz > window_radius_m * 1.35
		|| abs(TRANSFORM[3].y - camera_position.y) > vertical_half_extent_m * 1.45;
	if (!particles_enabled || camera_water_depth <= 0.05 || TRANSFORM[3].y >= sea_level - 0.015 || outside_window) {
		ACTIVE = false;
	} else {
		float age = clamp(CUSTOM.x + DELTA / max(LIFETIME, 0.001), 0.0, 1.0);
		CUSTOM.x = age;
		float birth_fade = smoothstep(0.0, 0.16, age);
		float death_fade = 1.0 - smoothstep(0.72, 1.0, age);
		float alpha = CUSTOM.z * birth_fade * death_fade;
		float wobble = sin(TIME * 0.65 + CUSTOM.w * 19.31 + TRANSFORM[3].x * 0.37 + TRANSFORM[3].z * 0.29);
		VELOCITY.y += wobble * 0.018 * drift_speed_scale * DELTA;
		COLOR = vec4(vec3(0.86, 0.96, 0.94), alpha);
	}
}
