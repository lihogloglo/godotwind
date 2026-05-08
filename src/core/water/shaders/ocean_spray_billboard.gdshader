shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, fog_disabled;

uniform sampler2D spray_texture : source_color, filter_linear_mipmap;
uniform vec3 spray_tint : source_color = vec3(0.92, 0.96, 1.0);
uniform float alpha_multiplier : hint_range(0.0, 2.0) = 1.0;

varying float particle_age;
varying float particle_energy;
varying float particle_seed;

void vertex() {
	particle_age = INSTANCE_CUSTOM.x;
	particle_energy = INSTANCE_CUSTOM.y;
	particle_seed = INSTANCE_CUSTOM.w;
}

void fragment() {
	vec4 tex = texture(spray_texture, UV);
	float age = clamp(particle_age, 0.0, 1.0);
	float energy = clamp(particle_energy, 0.0, 1.0);
	float seed = particle_seed;
	float edge_soften = 1.0 - smoothstep(0.78, 0.98, distance(UV, vec2(0.5)));
	float dissolve_noise = texture(spray_texture, UV * 1.75 + vec2(TIME * 0.09 + seed, TIME * 0.05)).b;
	float atomize = smoothstep(0.20, 0.92, age);
	float dissolve = mix(1.0, smoothstep(atomize * 0.58, 1.0, dissolve_noise + energy * 0.22), atomize);
	float alpha = tex.a * edge_soften * dissolve * COLOR.a * alpha_multiplier;
	ALBEDO = spray_tint * mix(vec3(0.78), vec3(1.0), energy);
	ALPHA = alpha;
}
