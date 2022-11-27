#pragma once

static const float PI = 3.14159265;
static const float EPSILON = 0.000000119;

float3 sphericalToCartesian(float sinTheta, float cosTheta, float phi) {
    return float3(sinTheta * cos(phi), cosTheta, sinTheta * sin(phi));
}

// (phi, theta) -- ([0, 2pi], [0, pi])
// assumes vector normalized
float2 cartesianToSpherical(float3 v) {
    float p = atan2(v.z, v.x);
    float phi = (p < 0) ? (p + 2 * PI) : p;
    float theta = acos(v.y);
    return float2(phi, theta);
}

float3 vectorToColor(float3 v) {
    return (v + 1.0) / 2.0;
}

float luminance(float3 color) {
    return 0.2126 * color.r +
           0.7152 * color.g +
           0.0722 * color.b;
}
