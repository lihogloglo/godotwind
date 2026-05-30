#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const uint FLAG_WET = 1u;
const uint FLAG_BROAD = 2u;
const uint FLAG_OCEAN = 4u;
const uint FLAG_CORRIDOR = 8u;
const uint FLAG_OUTLET = 16u;
const uint FLAG_RIVER = 32u;
const uint FLAG_STILL = 64u;

const uint REASON_NONE = 0u;
const uint REASON_STILL_BROAD = 1u;
const uint REASON_NO_OUTLET = 2u;
const uint REASON_TOO_SHORT = 3u;
const uint REASON_TOO_COASTAL = 4u;
const uint REASON_WIDTH = 5u;
const uint REASON_WEAK_TOPOLOGY = 6u;
const uint REASON_ACCEPTED = 255u;

const uint INF_DIST = 0x3fffffffu;
const int PASS_INIT_MASKS = 0;
const int PASS_BANK_DISTANCE = 1;
const int PASS_CORRIDOR_CANDIDATE = 2;
const int PASS_OCEAN_INIT = 3;
const int PASS_OCEAN_FLOOD = 4;
const int PASS_LABEL_INIT = 5;
const int PASS_LABEL_RELAX = 6;
const int PASS_OUTLET_INIT = 7;
const int PASS_OUTLET_RELAX = 8;
const int PASS_STATS_RESET = 9;
const int PASS_STATS_ACCUMULATE = 10;
const int PASS_CLASSIFY_AND_FLOW = 11;

const int STATS_FIELDS = 14;
const int STAT_AREA = 0;
const int STAT_MIN_X = 1;
const int STAT_MIN_Y = 2;
const int STAT_MAX_X = 3;
const int STAT_MAX_Y = 4;
const int STAT_BROAD_ADJ = 5;
const int STAT_OUTLET_PIXELS = 6;
const int STAT_MAX_OUTLET = 7;
const int STAT_WIDTH_SUM = 8;
const int STAT_WIDTH_MAX = 9;
const int STAT_HEIGHT_MIN_CM = 10;
const int STAT_HEIGHT_MAX_CM = 11;
const int STAT_RIVER_PIXELS = 12;
const int STAT_RESERVED = 13;

layout(set = 0, binding = 0, std430) readonly buffer HeightBuffer {
	float heights[];
};

layout(set = 0, binding = 1, std430) buffer FlowBuffer {
	uint flow[];
};

layout(set = 0, binding = 2, std430) buffer FlagBuffer {
	uint flags[];
};

layout(set = 0, binding = 3, std430) buffer LabelBuffer {
	uint labels[];
};

layout(set = 0, binding = 4, std430) buffer StatsBuffer {
	uint stats[];
};

layout(set = 0, binding = 5, std430) buffer ChangeBuffer {
	uint changed[];
};

layout(set = 0, binding = 6, std430) buffer BankDistanceBuffer {
	uint bank_distance[];
};

layout(set = 0, binding = 7, std430) buffer OutletDistanceBuffer {
	uint outlet_distance[];
};

layout(set = 0, binding = 8, std430) buffer WidthBuffer {
	uint local_width_px[];
};

layout(set = 0, binding = 9, std430) buffer ReasonBuffer {
	uint reasons[];
};

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int pass_index;
	int max_bank_radius_px;
	int min_bank_radius_px;
	int max_ocean_adjacency_percent;
	int min_inland_run_px;
	int topology_fallback_multiplier;
	float sea_level;
	float wet_tolerance;
	float texel_size_m;
	float max_encoded_speed_mps;
	float flow_speed_mps;
	float max_river_width_m;
	float min_river_width_m;
	float min_terrain_drop_m;
} pc;

bool in_bounds(ivec2 p) {
	return p.x >= 0 && p.y >= 0 && p.x < pc.width && p.y < pc.height;
}

int index_for(ivec2 p) {
	return p.y * pc.width + p.x;
}

int stats_index(uint label, int field) {
	return int((label - 1u) * uint(STATS_FIELDS) + uint(field));
}

float height_at(ivec2 p) {
	p.x = clamp(p.x, 0, pc.width - 1);
	p.y = clamp(p.y, 0, pc.height - 1);
	return heights[index_for(p)];
}

uint height_cm_at(ivec2 p) {
	return uint(clamp(round((height_at(p) + 4096.0) * 100.0), 0.0, 4294967295.0));
}

bool wet_at(ivec2 p) {
	return in_bounds(p) && (flags[index_for(p)] & FLAG_WET) != 0u;
}

bool corridor_at(ivec2 p) {
	return in_bounds(p) && (flags[index_for(p)] & FLAG_CORRIDOR) != 0u;
}

bool broad_at(ivec2 p) {
	return in_bounds(p) && (flags[index_for(p)] & (FLAG_BROAD | FLAG_OCEAN)) != 0u;
}

uint pack_rgba8(uint r, uint g, uint b, uint a) {
	return (r & 255u) | ((g & 255u) << 8u) | ((b & 255u) << 16u) | ((a & 255u) << 24u);
}

int distance_to_dry(ivec2 origin, ivec2 step_dir) {
	for (int step = 1; step <= pc.max_bank_radius_px; step++) {
		ivec2 p = origin + step_dir * step;
		if (!in_bounds(p)) {
			return pc.max_bank_radius_px + 1;
		}
		if (!wet_at(p)) {
			return step;
		}
	}
	return pc.max_bank_radius_px + 1;
}

void consider_axis(ivec2 p, ivec2 axis, inout int best_width, inout bool has_banks) {
	int a = distance_to_dry(p, axis);
	int b = distance_to_dry(p, -axis);
	if (a > pc.max_bank_radius_px || b > pc.max_bank_radius_px) {
		return;
	}
	int width_px = a + b;
	if (!has_banks || width_px < best_width) {
		best_width = width_px;
		has_banks = true;
	}
}

bool touches_broad_water(ivec2 p) {
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (broad_at(n)) {
				return true;
			}
		}
	}
	return false;
}

uint broad_adjacency_count(ivec2 p) {
	uint count = 0u;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			if (broad_at(p + ivec2(ox, oy))) {
				count += 1u;
			}
		}
	}
	return count;
}

void init_masks(ivec2 p, int idx) {
	bool wet = height_at(p) <= pc.sea_level + pc.wet_tolerance;
	flags[idx] = wet ? FLAG_WET : 0u;
	flow[idx] = 0u;
	labels[idx] = 0u;
	reasons[idx] = REASON_NONE;
	local_width_px[idx] = 0u;
	outlet_distance[idx] = INF_DIST;
	bank_distance[idx] = wet ? INF_DIST : 0u;
	changed[0] = 0u;
}

void relax_bank_distance(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_WET) == 0u) {
		bank_distance[idx] = 0u;
		return;
	}
	uint best = bank_distance[idx];
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (!in_bounds(n)) {
				best = min(best, 1u);
				continue;
			}
			uint step_cost = (abs(ox) + abs(oy) == 2) ? 2u : 1u;
			uint other = bank_distance[index_for(n)];
			if (other < INF_DIST) {
				best = min(best, other + step_cost);
			}
		}
	}
	if (best < bank_distance[idx]) {
		bank_distance[idx] = best;
		atomicExchange(changed[0], 1u);
	}
}

void build_corridor_candidate(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_WET) == 0u) {
		return;
	}
	int best_width = 0;
	bool has_banks = false;
	consider_axis(p, ivec2(1, 0), best_width, has_banks);
	consider_axis(p, ivec2(0, 1), best_width, has_banks);
	consider_axis(p, ivec2(1, 1), best_width, has_banks);
	consider_axis(p, ivec2(1, -1), best_width, has_banks);

	float width_m = float(best_width) * pc.texel_size_m;
	bool width_ok = has_banks && width_m >= pc.min_river_width_m && width_m <= pc.max_river_width_m;
	bool not_open_sheet = bank_distance[idx] <= uint(max(pc.max_bank_radius_px, 1));
	if (width_ok && not_open_sheet) {
		flags[idx] |= FLAG_CORRIDOR;
		local_width_px[idx] = uint(best_width);
	} else {
		flags[idx] |= FLAG_BROAD;
		reasons[idx] = REASON_STILL_BROAD;
	}
}

void init_ocean_core(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_WET) == 0u || (flags[idx] & FLAG_CORRIDOR) != 0u) {
		return;
	}
	flags[idx] |= FLAG_BROAD;
	if (p.x == 0 || p.y == 0 || p.x == pc.width - 1 || p.y == pc.height - 1) {
		flags[idx] |= FLAG_OCEAN;
	}
}

void flood_ocean_core(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_WET) == 0u || (flags[idx] & FLAG_CORRIDOR) != 0u || (flags[idx] & FLAG_OCEAN) != 0u) {
		return;
	}
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (in_bounds(n) && (flags[index_for(n)] & FLAG_OCEAN) != 0u) {
				flags[idx] |= FLAG_OCEAN | FLAG_BROAD;
				atomicExchange(changed[0], 1u);
				return;
			}
		}
	}
}

void init_labels(ivec2 p, int idx) {
	labels[idx] = ((flags[idx] & FLAG_CORRIDOR) != 0u) ? uint(idx + 1) : 0u;
}

void relax_labels(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_CORRIDOR) == 0u) {
		return;
	}
	uint current = labels[idx];
	uint best = current;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (!corridor_at(n)) {
				continue;
			}
			uint other = labels[index_for(n)];
			if (other != 0u) {
				best = min(best, other);
			}
		}
	}
	if (best < current) {
		labels[idx] = best;
		atomicExchange(changed[0], 1u);
	}
}

void init_outlet_distance(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_CORRIDOR) == 0u) {
		outlet_distance[idx] = INF_DIST;
		return;
	}
	if (touches_broad_water(p)) {
		outlet_distance[idx] = 0u;
		flags[idx] |= FLAG_OUTLET;
	} else {
		outlet_distance[idx] = INF_DIST;
	}
}

void relax_outlet_distance(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_CORRIDOR) == 0u) {
		return;
	}
	uint best = outlet_distance[idx];
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (!corridor_at(n)) {
				continue;
			}
			uint other = outlet_distance[index_for(n)];
			if (other >= INF_DIST) {
				continue;
			}
			uint step_cost = (abs(ox) + abs(oy) == 2) ? 2u : 1u;
			best = min(best, other + step_cost);
		}
	}
	if (best < outlet_distance[idx]) {
		outlet_distance[idx] = best;
		atomicExchange(changed[0], 1u);
	}
}

void stats_reset(int idx) {
	int base = idx * STATS_FIELDS;
	stats[base + STAT_AREA] = 0u;
	stats[base + STAT_MIN_X] = 0xffffffffu;
	stats[base + STAT_MIN_Y] = 0xffffffffu;
	stats[base + STAT_MAX_X] = 0u;
	stats[base + STAT_MAX_Y] = 0u;
	stats[base + STAT_BROAD_ADJ] = 0u;
	stats[base + STAT_OUTLET_PIXELS] = 0u;
	stats[base + STAT_MAX_OUTLET] = 0u;
	stats[base + STAT_WIDTH_SUM] = 0u;
	stats[base + STAT_WIDTH_MAX] = 0u;
	stats[base + STAT_HEIGHT_MIN_CM] = 0xffffffffu;
	stats[base + STAT_HEIGHT_MAX_CM] = 0u;
	stats[base + STAT_RIVER_PIXELS] = 0u;
	stats[base + STAT_RESERVED] = 0u;
}

void stats_accumulate(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_CORRIDOR) == 0u) {
		return;
	}
	uint label = labels[idx];
	if (label == 0u) {
		return;
	}
	atomicAdd(stats[stats_index(label, STAT_AREA)], 1u);
	atomicMin(stats[stats_index(label, STAT_MIN_X)], uint(p.x));
	atomicMin(stats[stats_index(label, STAT_MIN_Y)], uint(p.y));
	atomicMax(stats[stats_index(label, STAT_MAX_X)], uint(p.x));
	atomicMax(stats[stats_index(label, STAT_MAX_Y)], uint(p.y));
	atomicAdd(stats[stats_index(label, STAT_BROAD_ADJ)], broad_adjacency_count(p));
	if (outlet_distance[idx] == 0u) {
		atomicAdd(stats[stats_index(label, STAT_OUTLET_PIXELS)], 1u);
	}
	if (outlet_distance[idx] < INF_DIST) {
		atomicMax(stats[stats_index(label, STAT_MAX_OUTLET)], outlet_distance[idx]);
	}
	atomicAdd(stats[stats_index(label, STAT_WIDTH_SUM)], local_width_px[idx]);
	atomicMax(stats[stats_index(label, STAT_WIDTH_MAX)], local_width_px[idx]);
	uint hcm = height_cm_at(p);
	atomicMin(stats[stats_index(label, STAT_HEIGHT_MIN_CM)], hcm);
	atomicMax(stats[stats_index(label, STAT_HEIGHT_MAX_CM)], hcm);
}

bool accepted_river(int idx, out uint reject_reason) {
	reject_reason = REASON_NONE;
	uint label = labels[idx];
	if (label == 0u) {
		reject_reason = REASON_NO_OUTLET;
		return false;
	}
	uint area = stats[stats_index(label, STAT_AREA)];
	if (area == 0u) {
		reject_reason = REASON_NO_OUTLET;
		return false;
	}
	uint outlet_pixels = stats[stats_index(label, STAT_OUTLET_PIXELS)];
	uint max_outlet = stats[stats_index(label, STAT_MAX_OUTLET)];
	uint broad_adj = stats[stats_index(label, STAT_BROAD_ADJ)];
	uint width_sum = stats[stats_index(label, STAT_WIDTH_SUM)];
	uint width_max = stats[stats_index(label, STAT_WIDTH_MAX)];
	uint min_x = stats[stats_index(label, STAT_MIN_X)];
	uint min_y = stats[stats_index(label, STAT_MIN_Y)];
	uint max_x = stats[stats_index(label, STAT_MAX_X)];
	uint max_y = stats[stats_index(label, STAT_MAX_Y)];
	uint height_min = stats[stats_index(label, STAT_HEIGHT_MIN_CM)];
	uint height_max = stats[stats_index(label, STAT_HEIGHT_MAX_CM)];

	if (outlet_pixels == 0u || max_outlet >= INF_DIST) {
		reject_reason = REASON_NO_OUTLET;
		return false;
	}
	if (max_outlet < uint(max(pc.min_inland_run_px, 1))) {
		reject_reason = REASON_TOO_SHORT;
		return false;
	}
	uint ocean_adj_percent = (broad_adj * 100u) / max(area * 8u, 1u);
	uint outlet_percent = (outlet_pixels * 100u) / max(area, 1u);
	if (ocean_adj_percent > uint(pc.max_ocean_adjacency_percent) || outlet_percent > 35u) {
		reject_reason = REASON_TOO_COASTAL;
		return false;
	}
	float mean_width_m = (float(width_sum) / max(float(area), 1.0)) * pc.texel_size_m;
	float max_width_m = float(width_max) * pc.texel_size_m;
	if (mean_width_m < pc.min_river_width_m || max_width_m > pc.max_river_width_m * 1.15) {
		reject_reason = REASON_WIDTH;
		return false;
	}

	float bounds_w = float(max_x - min_x + 1u);
	float bounds_h = float(max_y - min_y + 1u);
	float aspect = max(bounds_w, bounds_h) / max(min(bounds_w, bounds_h), 1.0);
	float terrain_drop_m = float(max(int(height_max) - int(height_min), 0)) * 0.01;
	bool terrain_ok = terrain_drop_m >= pc.min_terrain_drop_m;
	bool topology_ok = max_outlet >= uint(pc.min_inland_run_px * max(pc.topology_fallback_multiplier, 1)) || aspect >= 3.0;
	if (!terrain_ok && !topology_ok) {
		reject_reason = REASON_WEAK_TOPOLOGY;
		return false;
	}
	reject_reason = REASON_ACCEPTED;
	return true;
}

vec2 outlet_flow_direction(ivec2 p, int idx) {
	uint current = outlet_distance[idx];
	uint best = current;
	ivec2 best_step = ivec2(0, 0);
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (!corridor_at(n)) {
				continue;
			}
			uint nd = outlet_distance[index_for(n)];
			if (nd < best) {
				best = nd;
				best_step = ivec2(ox, oy);
			}
		}
	}
	if (best_step != ivec2(0, 0)) {
		return normalize(vec2(best_step));
	}

	float h = height_at(p);
	float best_drop = 0.0;
	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			if (ox == 0 && oy == 0) {
				continue;
			}
			ivec2 n = p + ivec2(ox, oy);
			if (!corridor_at(n)) {
				continue;
			}
			float drop = h - height_at(n);
			if (drop > best_drop) {
				best_drop = drop;
				best_step = ivec2(ox, oy);
			}
		}
	}
	if (best_step != ivec2(0, 0)) {
		return normalize(vec2(best_step));
	}
	return vec2(0.0, 0.0);
}

void classify_and_flow(ivec2 p, int idx) {
	if ((flags[idx] & FLAG_WET) == 0u) {
		flow[idx] = 0u;
		reasons[idx] = REASON_NONE;
		return;
	}
	if ((flags[idx] & FLAG_CORRIDOR) == 0u) {
		flags[idx] |= FLAG_STILL;
		reasons[idx] = REASON_STILL_BROAD;
		flow[idx] = pack_rgba8(128u, 128u, 0u, 255u);
		return;
	}

	uint reject_reason = REASON_NONE;
	if (!accepted_river(idx, reject_reason)) {
		flags[idx] = (flags[idx] & ~FLAG_RIVER) | FLAG_STILL;
		reasons[idx] = reject_reason;
		flow[idx] = pack_rgba8(128u, 128u, 0u, 255u);
		return;
	}

	flags[idx] |= FLAG_RIVER;
	reasons[idx] = REASON_ACCEPTED;
	uint label = labels[idx];
	if (label != 0u) {
		atomicAdd(stats[stats_index(label, STAT_RIVER_PIXELS)], 1u);
	}
	vec2 dir = outlet_flow_direction(p, idx);
	if (length(dir) <= 0.0001) {
		dir = vec2(0.0, 1.0);
	}
	dir = normalize(dir);
	uint r = uint(clamp(round((dir.x * 0.5 + 0.5) * 255.0), 0.0, 255.0));
	uint g = uint(clamp(round((dir.y * 0.5 + 0.5) * 255.0), 0.0, 255.0));
	uint b = uint(clamp(round((pc.flow_speed_mps / max(pc.max_encoded_speed_mps, 0.001)) * 255.0), 1.0, 255.0));
	flow[idx] = pack_rgba8(r, g, b, 255u);
}

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (!in_bounds(p)) {
		return;
	}
	int idx = index_for(p);
	if (pc.pass_index == PASS_INIT_MASKS) {
		init_masks(p, idx);
	} else if (pc.pass_index == PASS_BANK_DISTANCE) {
		relax_bank_distance(p, idx);
	} else if (pc.pass_index == PASS_CORRIDOR_CANDIDATE) {
		build_corridor_candidate(p, idx);
	} else if (pc.pass_index == PASS_OCEAN_INIT) {
		init_ocean_core(p, idx);
	} else if (pc.pass_index == PASS_OCEAN_FLOOD) {
		flood_ocean_core(p, idx);
	} else if (pc.pass_index == PASS_LABEL_INIT) {
		init_labels(p, idx);
	} else if (pc.pass_index == PASS_LABEL_RELAX) {
		relax_labels(p, idx);
	} else if (pc.pass_index == PASS_OUTLET_INIT) {
		init_outlet_distance(p, idx);
	} else if (pc.pass_index == PASS_OUTLET_RELAX) {
		relax_outlet_distance(p, idx);
	} else if (pc.pass_index == PASS_STATS_RESET) {
		stats_reset(idx);
	} else if (pc.pass_index == PASS_STATS_ACCUMULATE) {
		stats_accumulate(p, idx);
	} else if (pc.pass_index == PASS_CLASSIFY_AND_FLOW) {
		classify_and_flow(p, idx);
	}
}
