#pragma once

static const float PI = 3.14159265;
static const float EPSILON = 0.000000119;

bool sameHemisphere(float3 v1, float3 v2) {
    return v1.z * v2.z > 0.0;
}

float3 sphericalToCartesian(float sinTheta, float cosTheta, float phi) {
    return float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}