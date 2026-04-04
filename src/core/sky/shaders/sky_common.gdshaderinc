// Sky scattering functions — shared between sky.gdshader and potential future passes.
// Rayleigh + Mie single-scatter with multi-scatter energy rescaling.
// References: Hillaire 2020 §5.3, Preetham 1999, Sky3D (MIT, TokisanGames).

const float PLANET_RADIUS = 6371000.0; // meters
const float ATMOSPHERE_RADIUS = 6471000.0; // meters (100km atmosphere)
const float INV_PI = 1.0 / PI;
const float INV_TAU = 1.0 / TAU;
const float THREE_OVER_16PI = 3.0 / (16.0 * PI);
const float ONE_OVER_4PI = 1.0 / (4.0 * PI);

// ---- Phase Functions ----

// Rayleigh phase function (molecular scatter is symmetric forward/backward).
float rayleigh_phase(float cos_theta) {
	return THREE_OVER_16PI * (1.0 + cos_theta * cos_theta);
}

// Henyey-Greenstein phase function (Mie scatter is forward-biased).
float hg_phase(float cos_theta, float g) {
	float g2 = g * g;
	float denom = 1.0 + g2 - 2.0 * g * cos_theta;
	return ONE_OVER_4PI * (1.0 - g2) / (denom * sqrt(denom));
}

// ---- Ray-Sphere Intersection ----

// Returns distance to intersection with sphere, or -1.0 if no hit.
float ray_sphere_intersect(vec3 ray_origin, vec3 ray_dir, float sphere_radius) {
	float b = dot(ray_origin, ray_dir);
	float c = dot(ray_origin, ray_origin) - sphere_radius * sphere_radius;
	float discriminant = b * b - c;
	if (discriminant < 0.0) return -1.0;
	return -b + sqrt(discriminant);
}

// ---- Main Scattering Integration ----

// Compute single-scatter Rayleigh + Mie along a view ray.
// Returns: vec3 inscattered light (linear HDR radiance).
// out_transmittance: transmittance from camera to atmosphere edge (for star dimming).
vec3 compute_atmosphere(
	vec3 view_dir,
	vec3 sun_dir,
	vec3 rayleigh_coeff,
	float mie_coeff,
	float mie_g,
	float rayleigh_sh,
	float mie_sh,
	float turbidity_factor,
	out vec3 out_transmittance
) {
	// Camera at planet surface
	vec3 cam_pos = vec3(0.0, PLANET_RADIUS + 1.0, 0.0);

	// Ray length through atmosphere
	float atm_dist = ray_sphere_intersect(cam_pos, view_dir, ATMOSPHERE_RADIUS);
	if (atm_dist < 0.0) {
		out_transmittance = vec3(1.0);
		return vec3(0.0);
	}

	// Integration parameters
	const int NUM_STEPS = 16;
	float step_size = atm_dist / float(NUM_STEPS);

	// Scattering coefficients (turbidity scales Mie)
	vec3 beta_r = rayleigh_coeff;
	float beta_m = mie_coeff * turbidity_factor;

	// Phase function values (constant along ray for single-scatter)
	float cos_theta = dot(view_dir, sun_dir);
	float phase_r = rayleigh_phase(cos_theta);
	float phase_m = hg_phase(cos_theta, mie_g);

	// Accumulate inscattered light and optical depth
	vec3 total_rayleigh = vec3(0.0);
	float total_mie = 0.0;
	float optical_depth_r = 0.0;
	float optical_depth_m = 0.0;

	for (int i = 0; i < NUM_STEPS; i++) {
		float t = (float(i) + 0.5) * step_size;
		vec3 sample_pos = cam_pos + view_dir * t;

		// Height above planet surface (clamp to 0: prevent underground NaN from Inf density)
		float height = max(length(sample_pos) - PLANET_RADIUS, 0.0);

		// Local density at this height
		float density_r = exp(-height / rayleigh_sh) * step_size;
		float density_m = exp(-height / mie_sh) * step_size;

		// Accumulate optical depth from camera to sample point
		optical_depth_r += density_r;
		optical_depth_m += density_m;

		// Optical depth from sample point to sun (simplified: use height-based approximation)
		float sun_cos_zenith = dot(normalize(sample_pos), sun_dir);
		float sun_ray_length = ray_sphere_intersect(sample_pos, sun_dir, ATMOSPHERE_RADIUS);
		if (sun_ray_length < 0.0) continue;

		// Simple height-based sun optical depth (4 steps for performance)
		float sun_od_r = 0.0;
		float sun_od_m = 0.0;
		float sun_step = sun_ray_length / 4.0;
		for (int j = 0; j < 4; j++) {
			float sun_t = (float(j) + 0.5) * sun_step;
			vec3 sun_sample = sample_pos + sun_dir * sun_t;
			float sun_height = max(length(sun_sample) - PLANET_RADIUS, 0.0);
			sun_od_r += exp(-sun_height / rayleigh_sh) * sun_step;
			sun_od_m += exp(-sun_height / mie_sh) * sun_step;
		}

		// Combined extinction (camera→sample + sample→sun)
		vec3 extinction = beta_r * (optical_depth_r + sun_od_r)
		                + vec3(beta_m) * (optical_depth_m + sun_od_m);
		vec3 attenuation = exp(-extinction);

		// Accumulate inscattered light at this sample
		total_rayleigh += density_r * attenuation;
		// Mie uses red channel only — wavelength-independent scatter, slight blue underestimate at high turbidity
		total_mie += density_m * attenuation.r;
	}

	// Combine Rayleigh and Mie with phase functions
	vec3 inscatter = total_rayleigh * beta_r * phase_r + vec3(total_mie * beta_m * phase_m);

	// Transmittance from camera through entire view ray
	out_transmittance = exp(-(beta_r * optical_depth_r + vec3(beta_m) * optical_depth_m));

	return inscatter;
}

// ---- Celestial Rendering ----

// Sun disc with limb darkening.
vec3 render_sun_disc(vec3 view_dir, vec3 sun_dir, float angular_radius, float energy) {
	float cos_angle = dot(view_dir, sun_dir);
	float sun_cos_radius = cos(angular_radius);

	if (cos_angle < sun_cos_radius) return vec3(0.0);

	// Limb darkening: center is brighter than edges
	float center_dist = 1.0 - (cos_angle - sun_cos_radius) / (1.0 - sun_cos_radius);
	float limb = 1.0 - center_dist * center_dist * 0.3;

	return vec3(energy * limb);
}

// Ray-sphere intersection for moon rendering (adapted from Sky3D, MIT).
// Returns intersection parameter, or -1.0 if no hit.
float simple_sphere_intersect(vec3 ray_dir, vec3 sphere_pos, float radius) {
	vec3 oc = -sphere_pos;
	float b = dot(oc, ray_dir);
	float c = dot(oc, oc) - radius * radius;
	float h = b * b - c;
	float valid = step(0.0, h);
	h = sqrt(max(h, 0.0));
	return mix(-1.0, -b - h, valid);
}

// Moon disc with simple N dot L lighting.
// In Phase 1: simple white disc. Phase 2 adds texture.
vec3 render_moon_disc(vec3 view_dir, vec3 moon_dir, vec3 sun_dir, float angular_radius, float energy) {
	float cos_angle = dot(view_dir, moon_dir);
	float moon_cos_radius = cos(angular_radius);

	if (cos_angle < moon_cos_radius) return vec3(0.0);

	// Sphere surface normal at the visible point
	vec3 moon_normal = normalize(view_dir - moon_dir);
	float ndotl = max(dot(moon_normal, sun_dir), 0.0);

	// Phase lighting: lit by sun, creates crescent shape
	return vec3(energy * ndotl * 0.5);
}

// Star field from equirectangular panorama.
vec3 render_stars(vec3 view_dir, sampler2D panorama, mat3 rotation, float energy) {
	vec3 rotated = rotation * view_dir;
	// Equirectangular UV mapping
	float u = atan(rotated.z, rotated.x) * INV_TAU + 0.5;
	float v = asin(clamp(rotated.y, -1.0, 1.0)) * INV_PI + 0.5;
	vec3 star_color = texture(panorama, vec2(u, v)).rgb;
	return star_color * energy;
}

// Equirectangular UV from direction (for use without panorama texture).
vec2 equirect_uv(vec3 dir) {
	return vec2(
		atan(dir.z, dir.x) * INV_TAU + 0.5,
		asin(clamp(dir.y, -1.0, 1.0)) * INV_PI + 0.5
	);
}
