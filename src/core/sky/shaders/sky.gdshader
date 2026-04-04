shader_type sky;
render_mode use_debanding;

// GodotwindSky — Analytical Rayleigh+Mie sky with multi-scatter approximation.
// Replaces Sky3D's Preetham single-scatter model.
// References: Hillaire 2020, Preetham 1999, Sky3D (MIT, TokisanGames).
// Outputs linear HDR radiance — NO tonemapping (Environment handles that).

#include "sky_common.gdshaderinc"

// ---- Atmosphere Uniforms ----
uniform vec3 rayleigh_coefficient = vec3(5.5e-6, 13.0e-6, 22.4e-6);
uniform float mie_coefficient = 21e-6;
uniform float mie_anisotropy : hint_range(0.0, 0.999) = 0.76;
uniform vec3 ozone_coefficient = vec3(0.0);
uniform float rayleigh_scale_height = 8400.0;
uniform float mie_scale_height = 1200.0;
uniform float multi_scatter_factor : hint_range(0.0, 1.0) = 0.5;
uniform float turbidity : hint_range(1.0, 10.0) = 2.0;
uniform vec3 ground_albedo = vec3(0.3);

// ---- Celestial Uniforms ----
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 moon_direction = vec3(0.0, -1.0, 0.0);
uniform float sun_disk_size : hint_range(0.001, 0.1) = 0.0087; // ~0.5 degrees
uniform float sun_energy : hint_range(0.0, 100.0) = 22.0;
uniform vec3 sun_color = vec3(1.0, 0.95, 0.9);
uniform float moon_disk_size : hint_range(0.001, 0.1) = 0.009;
uniform float moon_energy : hint_range(0.0, 5.0) = 0.5;
uniform sampler2D moon_texture : filter_linear;
uniform bool moon_texture_enabled = false;

// ---- Stars ----
uniform sampler2D star_panorama : filter_linear, repeat_enable;
uniform mat3 star_rotation;
uniform float star_energy : hint_range(0.0, 2.0) = 0.3;
uniform bool star_panorama_enabled = false;

// ---- Ground ----
uniform vec3 ground_color = vec3(0.15, 0.12, 0.1);

// ---- Cloud Darkening ----
uniform float cloud_coverage : hint_range(0.0, 1.0) = 0.0;

// ---- Night Glow ----
uniform float night_intensity : hint_range(0.0, 0.1) = 0.005;


void sky() {
	vec3 view_dir = EYEDIR;

	// --- Atmospheric Scattering ---
	vec3 transmittance;
	vec3 inscatter = compute_atmosphere(
		view_dir,
		sun_direction,
		rayleigh_coefficient,
		mie_coefficient,
		mie_anisotropy,
		rayleigh_scale_height,
		mie_scale_height,
		turbidity,
		transmittance
	);

	// Solar illuminance (sun color + energy drives the scattering)
	// The compute_atmosphere returns normalized scatter; scale by sun radiance
	float sun_visible = step(0.0, sun_direction.y + 0.1); // Allow scatter below horizon for twilight
	float sun_zenith = clamp(sun_direction.y, -0.1, 1.0);
	float sun_intensity_factor = clamp((sun_zenith + 0.1) / 0.2, 0.0, 1.0);
	inscatter *= sun_color * sun_energy * sun_intensity_factor;

	// --- Multi-Scatter Rescaling ---
	// Hillaire 2020 §5.3: higher-order scattering acts as isotropic ambient.
	// Rescale factor from geometric series: 1/(1 - albedo * factor)
	// This brightens the horizon at low sun angles (the main weakness of single-scatter).
	// Realistic scatter albedo: Rayleigh ~1.0 (no absorption), Mie ~0.9 (10% absorption).
	// Weighted average based on relative contribution at sea level.
	float avg_rayleigh = (rayleigh_coefficient.x + rayleigh_coefficient.y + rayleigh_coefficient.z) / 3.0;
	float effective_mie = mie_coefficient * turbidity;
	float rayleigh_weight = avg_rayleigh / (avg_rayleigh + effective_mie + 1e-10);
	float scatter_albedo = rayleigh_weight * 1.0 + (1.0 - rayleigh_weight) * 0.9;
	scatter_albedo = clamp(scatter_albedo, 0.0, 0.99);
	float ms_factor = 1.0 / (1.0 - scatter_albedo * multi_scatter_factor);
	inscatter *= ms_factor;

	// --- Night Sky Ambient ---
	// Faint ambient glow at night (airglow + scattered starlight)
	float night_factor = clamp(-sun_direction.y * 2.0, 0.0, 1.0);
	inscatter += vec3(0.02, 0.04, 0.08) * night_intensity * night_factor;

	// --- Sun Disc ---
	vec3 sun_disc = render_sun_disc(view_dir, sun_direction, sun_disk_size, sun_energy);
	sun_disc *= sun_color;
	// Attenuate through atmosphere (sun near horizon is reddened)
	sun_disc *= transmittance;
	inscatter += sun_disc;

	// --- Moon ---
	vec3 moon = vec3(0.0);
	float moon_vis = 0.0;
	if (moon_texture_enabled) {
		// Sphere intersection for textured moon (adapted from Sky3D, MIT)
		float moon_intersect = simple_sphere_intersect(view_dir, moon_direction, moon_disk_size);
		float threshold = -1.0 + sqrt(moon_disk_size);
		if (moon_intersect > threshold) {
			// Fade out during day to prevent black disc artifact
			float day_fade = clamp(-sun_direction.y * 3.0 + 0.5, 0.0, 1.0);
			moon_vis = day_fade;
			vec3 moon_normal = normalize(view_dir * moon_intersect - moon_direction);
			float moon_ndotl = clamp(dot(moon_normal, sun_direction), 0.0, 1.0);
			// Sample moon texture via equirectangular projection on sphere
			vec2 moon_uv = equirect_uv(moon_normal);
			vec3 moon_tex = texture(moon_texture, moon_uv).rgb;
			moon = moon_vis * moon_ndotl * moon_tex * moon_energy * 2.0;
		}
	} else {
		moon = render_moon_disc(view_dir, moon_direction, sun_direction, moon_disk_size, moon_energy);
	}
	moon *= transmittance;
	inscatter += moon;

	// --- Stars ---
	if (star_panorama_enabled) {
		vec3 stars = render_stars(view_dir, star_panorama, star_rotation, star_energy);
		// Stars dimmed by atmospheric scatter (invisible during day)
		stars *= transmittance;
		// Mask stars behind moon disc
		float moon_mask = step(cos(moon_disk_size), dot(view_dir, moon_direction));
		stars *= (1.0 - moon_mask);
		inscatter += stars;
	} else {
		// Procedural stars using 3D direction hash (no equirectangular grid artifacts)
		vec3 star_dir = star_rotation * view_dir;
		// Quantize in 3D to create star cells, avoiding UV seam issues
		vec3 star_cell = floor(star_dir * 200.0);
		float star_hash = fract(sin(dot(star_cell, vec3(127.1, 311.7, 74.7))) * 43758.5453);
		float star_brightness = step(0.995, star_hash) * star_hash * star_energy;
		// Vary star color slightly (warm/cool)
		float color_hash = fract(star_hash * 17.13);
		vec3 star_tint = mix(vec3(0.8, 0.85, 1.0), vec3(1.0, 0.9, 0.75), color_hash);
		vec3 stars = star_tint * star_brightness;
		stars *= transmittance;
		float moon_mask = step(cos(moon_disk_size), dot(view_dir, moon_direction));
		stars *= (1.0 - moon_mask);
		inscatter += stars;
	}

	// --- Horizon Brightening ---
	// Near the horizon, the long ray path causes heavy extinction (dark band).
	// Multi-scatter partially fixes this, but we also lerp toward a brighter horizon
	// to prevent a visible dark band between sky and ground.
	float horizon_factor = 1.0 - smoothstep(0.0, 0.12, abs(view_dir.y));
	if (horizon_factor > 0.0) {
		// Boost horizon brightness using sun color scaled by altitude
		float sun_horizon = clamp(sun_direction.y + 0.1, 0.0, 1.0);
		vec3 horizon_boost = sun_color * sun_energy * 0.04 * sun_horizon;
		inscatter = mix(inscatter, max(inscatter, horizon_boost), horizon_factor * 0.6);
	}

	// --- Ground / Below Horizon ---
	// Below the horizon, blend from the horizon scatter color toward a ground tint.
	// This affects the sky dome background AND the IBL lower hemisphere.
	if (view_dir.y < 0.0) {
		vec3 horizon_color = inscatter;
		vec3 ground_tint = ground_color + horizon_color * ground_albedo;
		float ground_blend = smoothstep(0.0, -0.15, view_dir.y);
		inscatter = mix(horizon_color, ground_tint, ground_blend);
	}

	// --- Cloud Darkening ---
	// When volumetric clouds cover the sky, darken the atmosphere behind them.
	// The cloud plugin does actual cloud rendering — we just dim the backdrop.
	inscatter *= 1.0 - cloud_coverage * 0.4;

	// Output linear HDR radiance — NO tonemapping here.
	// Godot's Environment handles tonemapping (FILMIC/ACES/AGX).
	COLOR = inscatter;
}
