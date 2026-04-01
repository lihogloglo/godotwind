#[vertex]
#version 450

#include "./CloudsInc.comp"

#define STAGE_VERTEX
#include "./SunshineCloudsDisplay.rast"
#undef STAGE_VERTEX

#[fragment]
#version 450

#include "./CloudsInc.comp"
#include "./SunshineCloudsDisplay.rast"
