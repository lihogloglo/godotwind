// Retained as an import-compatibility shim. The production ripple pipeline uses
// water_ripple_scroll.glsl + water_ripple_splat.glsl + water_ripple_simulate.glsl.
#[compute]
#version 460

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

void main() {
}
