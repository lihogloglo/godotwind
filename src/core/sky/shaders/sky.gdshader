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
uniform float scintillation_amount : hint_range(0.0, 1.0) = 0.15;
uniform float scintillation_speed : hint_range(0.0, 10.0) = 1.5;

// ---- Mie Halos ----
uniform float sun_halo_intensity : hint_range(0.0, 5.0) = 0.4;
uniform float sun_halo_g : hint_range(0.9, 0.999) = 0.96;
uniform float moon_halo_intensity : hint_range(0.0, 5.0) = 0.05;
uniform float moon_halo_g : hint_range(0.9, 0.999) = 0.95;

// ---- Color Tinting ----
uniform vec3 day_tint = vec3(1.0, 1.0, 1.0);
uniform vec3 night_tint = vec3(0.6, 0.7, 1.0);
uniform vec3 horizon_tint = vec3(1.0, 0.85, 0.7);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.3;

// ---- Cirrus Clouds ----
uniform bool cirrus_visible = true;
uniform sampler2D cirrus_texture : filter_linear, repeat_enable;
uniform float cirrus_coverage : hint_range(0.0, 1.0) = 0.4;
uniform float cirrus_absorption : hint_range(0.0, 10.0) = 2.0;
uniform float cirrus_intensity : hint_range(0.0, 20.0) = 8.0;
uniform float cirrus_thickness : hint_range(0.0, 1.0) = 0.4;
uniform float cirrus_size : hint_range(0.1, 5.0) = 1.0;
uniform vec2 cirrus_scroll1 = vec2(0.0); // UV offset 1 (animated from GDScript)
uniform vec2 cirrus_scroll2 = vec2(0.0); // UV offset 2 (different speed)
uniform vec3 cirrus_day_color = vec3(1.0, 0.98, 0.95);
uniform vec3 cirrus_night_color = vec3(0.15, 0.18, 0.25);

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

	// --- Sun Disc + Mie Halo ---
	vec3 sun_disc = render_sun_disc(view_dir, sun_direction, sun_disk_size, sun_energy);
	sun_disc *= sun_color;
	// Attenuate through atmosphere (sun near horizon is reddened)
	sun_disc *= transmittance;
	inscatter += sun_disc;

	// Sun Mie halo — visible corona around the sun disc
	if (sun_halo_intensity > 0.0 && sun_visible > 0.0) {
		vec3 sun_halo = render_mie_halo(view_dir, sun_direction, sun_halo_g, sun_halo_intensity, sun_color);
		sun_halo *= transmittance * sun_intensity_factor;
		inscatter += sun_halo;
	}

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

	// Moon Mie halo — faint corona around the moon (visible at night when moon is up)
	if (moon_halo_intensity > 0.0 && moon_direction.y > 0.0) {
		float moon_night_factor = clamp(-sun_direction.y * 3.0 + 0.5, 0.0, 1.0); // Only at night
		if (moon_night_factor > 0.0) {
			vec3 moon_halo = render_mie_halo(view_dir, moon_direction, moon_halo_g, moon_halo_intensity, vec3(0.7, 0.75, 0.9));
			moon_halo *= transmittance * moon_night_factor * clamp(moon_direction.y, 0.0, 1.0);
			inscatter += moon_halo;
		}
	}

	// --- Stars ---
	if (star_panorama_enabled) {
		vec3 stars = render_stars(view_dir, star_panorama, star_rotation, star_energy);
		// Scintillation (twinkling)
		if (scintillation_amount > 0.0) {
			vec3 rotated_dir = star_rotation * view_dir;
			stars *= star_scintillation(rotated_dir, TIME, scintillation_speed, scintillation_amount);
		}
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
		// Scintillation (twinkling)
		if (scintillation_amount > 0.0) {
			star_brightness *= star_scintillation(star_dir, TIME, scintillation_speed, scintillation_amount);
		}
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

	// --- Cirrus Clouds ---
	// Thin high-altitude wisps rendered as a 2D noise layer on a flat ceiling projection.
	// Technique: Sky3D (MIT) / industry standard — 2 texture fetches, Beer's law extinction.
	if (cirrus_visible && view_dir.y > 0.01) {
		// Project view ray onto flat ceiling plane
		vec2 cirrus_uv = view_dir.xz / view_dir.y * cirrus_size;
		// Sample noise twice at different scroll offsets for evolving wispy shapes
		float n1 = textureLod(cirrus_texture, cirrus_uv + cirrus_scroll1, 0.0).r;
		float n2 = textureLod(cirrus_texture, cirrus_uv + cirrus_scroll2, 0.0).r;
		float density = clamp((n1 + n2) * 0.5 - (1.0 - cirrus_coverage), 0.0, 1.0);

		if (density > 0.0) {
			// Beer's law self-shadowing
			float transmittance_cloud = clamp(exp(-cirrus_absorption * density), 0.0, 1.0);
			float alpha = clamp(density * cirrus_thickness, 0.0, 1.0);

			// Tint by time of day (warm at day, blue-grey at night)
			float day_factor = clamp(sun_direction.y + 0.1, 0.0, 1.0);
			vec3 cloud_color = mix(cirrus_night_color, cirrus_day_color, day_factor);

			// Horizon fade — cirrus shouldn't be visible at low angles (too much atmosphere)
			float horizon_fade = smoothstep(0.01, 0.15, view_dir.y);
			alpha *= horizon_fade;

			// Composite over sky: cloud_color * density * transmittance * intensity
			vec3 cirrus_contrib = cloud_color * density * transmittance_cloud * cirrus_intensity;
			inscatter = mix(inscatter, cirrus_contrib + inscatter * (1.0 - alpha * 0.5), alpha);
		}
	}

	// --- Color Tinting ---
	// Blend between physically-computed scatter and artist tint colors.
	// Allows matching Morrowind's aesthetic without abandoning physical accuracy.
	if (tint_strength > 0.0) {
		float sun_alt_01 = clamp(sun_direction.y + 0.1, 0.0, 1.0); // 0=night, 1=day
		// Choose tint based on time of day
		vec3 time_tint = mix(night_tint, day_tint, sun_alt_01);
		// Horizon tint blends in near the horizon (strongest at sunrise/sunset)
		float horizon_blend = 1.0 - smoothstep(0.0, 0.25, abs(view_dir.y));
		float sunset_factor = 1.0 - smoothstep(0.0, 0.3, abs(sun_direction.y));
		vec3 final_tint = mix(time_tint, horizon_tint, horizon_blend * sunset_factor);
		// Apply as multiplicative tint, lerped by tint_strength
		inscatter *= mix(vec3(1.0), final_tint, tint_strength);
	}

	// --- Cloud Darkening ---
	// When volumetric clouds cover the sky, darken the atmosphere behind them.
	// The cloud plugin does actual cloud rendering — we just dim the backdrop.
	inscatter *= 1.0 - cloud_coverage * 0.4;

	// Output linear HDR radiance — NO tonemapping here.
	// Godot's Environment handles tonemapping (FILMIC/ACES/AGX).
	COLOR = inscatter;
}
