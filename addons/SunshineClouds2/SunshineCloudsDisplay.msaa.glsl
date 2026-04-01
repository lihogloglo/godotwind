#[vertex]
#version 450

#define MSAA_ENABLED 1

#include "./CloudsInc.comp"

#define STAGE_VERTEX
#include "./SunshineCloudsDisplay.rast"
#undef STAGE_VERTEX

#[fragment]
#version 450

#define MSAA_ENABLED 1

#include "./CloudsInc.comp"
#include "./SunshineCloudsDisplay.rast"
