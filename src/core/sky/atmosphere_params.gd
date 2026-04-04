class_name AtmosphereParams
extends RefCounted
## Atmospheric scattering parameters for the sky system.
## Framework-level defaults match Earth's atmosphere at sea level.
## Game-specific adapters (e.g., WeatherRenderer) modify these for weather effects.

## Rayleigh scattering coefficient (wavelength-dependent, per-meter).
## Standard Earth atmosphere at sea level.
var rayleigh_coefficient: Vector3 = Vector3(5.5e-6, 13.0e-6, 22.4e-6)

## Mie scattering coefficient (aerosol, wavelength-independent).
var mie_coefficient: float = 21e-6

## Henyey-Greenstein anisotropy parameter (0=isotropic, 0.76=forward scatter).
var mie_anisotropy: float = 0.76

## Ozone absorption coefficient (Chappuis band). Zero for Phase 1.
var ozone_coefficient: Vector3 = Vector3.ZERO

## Atmospheric turbidity (1=clear mountain air, 2=clear, 5=hazy, 10=very hazy).
var turbidity: float = 2.0

## Ground albedo (affects multi-scatter ground reflection contribution).
var ground_albedo: Color = Color(0.3, 0.3, 0.3)

## Rayleigh scale height in meters (8.4 km default).
var rayleigh_scale_height: float = 8400.0

## Mie scale height in meters (1.2 km default).
var mie_scale_height: float = 1200.0

## Multi-scatter strength (0=single-scatter only, 0.5=default, 1.0=maximum).
var multi_scatter_factor: float = 0.5


## Returns a dictionary of shader uniform name -> value pairs.
## Turbidity is passed as a separate uniform — the shader applies it to Mie.
func to_shader_params() -> Dictionary:
	return {
		"rayleigh_coefficient": rayleigh_coefficient,
		"mie_coefficient": mie_coefficient,
		"mie_anisotropy": mie_anisotropy,
		"ozone_coefficient": ozone_coefficient,
		"rayleigh_scale_height": rayleigh_scale_height,
		"mie_scale_height": mie_scale_height,
		"multi_scatter_factor": multi_scatter_factor,
		"ground_albedo": Vector3(ground_albedo.r, ground_albedo.g, ground_albedo.b),
	}


## Reset to Earth defaults.
func reset() -> void:
	rayleigh_coefficient = Vector3(5.5e-6, 13.0e-6, 22.4e-6)
	mie_coefficient = 21e-6
	mie_anisotropy = 0.76
	ozone_coefficient = Vector3.ZERO
	turbidity = 2.0
	ground_albedo = Color(0.3, 0.3, 0.3)
	rayleigh_scale_height = 8400.0
	mie_scale_height = 1200.0
	multi_scatter_factor = 0.5
