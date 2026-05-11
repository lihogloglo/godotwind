shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, fog_disabled;

uniform vec3 mote_tint : source_color = vec3(0.82, 0.96, 0.93);
uniform float alpha_multiplier : hint_range(0.0, 2.0) = 0.75;

varying float particle_age;
varying float particle_alpha;

void vertex() {
	particle_age = INSTANCE_CUSTOM.x;
	particle_alpha = INSTANCE_CUSTOM.z;
}

void fragment() {
	float d = distance(UV, vec2(0.5));
	float soft_disc = 1.0 - smoothstep(0.10, 0.50, d);
	float core = 1.0 - smoothstep(0.0, 0.18, d);
	float age_gate = smoothstep(0.0, 0.12, particle_age) * (1.0 - smoothstep(0.84, 1.0, particle_age));
	float alpha = clamp((soft_disc * 0.72 + core * 0.28) * particle_alpha * alpha_multiplier * age_gate, 0.0, 1.0);
	ALBEDO = mote_tint;
	ALPHA = alpha;
}
