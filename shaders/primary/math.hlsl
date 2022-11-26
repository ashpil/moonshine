#pragma once

static const float PI = 3.14159265;
static const float EPSILON = 0.000000119;

float3 sphericalToCartesian(float sinTheta, float cosTheta, float phi) {
    return float3(sinTheta * cos(phi), cosTheta, sinTheta * sin(phi));
}

float3 vectorToColor(float3 v) {
    return (v + 1.0) / 2.0;
}
