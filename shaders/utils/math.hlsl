#pragma once

static const float PI = 3.14159265;
static const float EPSILON = 0.000000119;
static const float INFINITY = 1000000000000; // pranked
static const uint MAX_UINT = 0xFFFFFFFF;
static const float AIR_IOR = 1.000277;

float3 sphericalToCartesian(float sinTheta, float cosTheta, float phi) {
    return float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

// (phi, theta) -- ([0, 2pi], [0, pi])
// assumes vector normalized
float2 cartesianToSpherical(float3 v) {
    float p = atan2(v.y, v.x);
    float phi = (p < 0) ? (p + 2 * PI) : p;
    float theta = acos(v.z);
    return float2(phi, theta);
}

float3 vectorToColor(float3 v) {
    return (v + 1.0) / 2.0;
}

bool isBlack(float3 c) {
    return all(c == float3(0, 0, 0));
}

float luminance(float3 color) {
    return 0.2126 * color.r +
           0.7152 * color.g +
           0.0722 * color.b;
}

float3 faceForward(float3 n, float3 d) {
    return dot(n, d) > 0 ? n : -n;
}

float2 faceForward(float2 n, float2 d) {
    return dot(n, d) > 0 ? n : -n;
}

// https://research.nvidia.com/publication/2019-03_fast-and-robust-method-avoiding-self-intersection
float3 offsetAlongNormal(float3 p, float3 n) {
    float origin = 1.0f / 32.0f;
    float float_scale = 1.0f / 65536.0f;
    float int_scale = 256.0f;

    int3 of_i = n * int_scale;

    float3 p_i = asfloat(asint(p) + select(p < 0.f, -of_i, of_i));

    return select(abs(p) < origin, p + n * float_scale, p_i);
}

float2 offsetAlongNormal(float2 p, float2 n) {
    float origin = 1.0f / 32.0f;
    float float_scale = 1.0f / 65536.0f;
    float int_scale = 256.0f;

    int2 of_i = n * int_scale;

    float2 p_i = asfloat(asint(p) + select(p < 0.f, -of_i, of_i));

    return select(abs(p) < origin, p + n * float_scale, p_i);
}

void coordinateSystem(float3 v1, out float3 v2, out float3 v3) {
    if (abs(v1.x) > abs(v1.y)) {
        v2 = float3(-v1.z, 0.0, v1.x) / sqrt(v1.x * v1.x + v1.z * v1.z);
    } else {
        v2 = float3(0.0, v1.z, -v1.y) / sqrt(v1.y * v1.y + v1.z * v1.z);
    }

    v3 = cross(v2, v1);
}

// TODO: switch to this when figure it why it doesn't work
// void coordinateSystem(float3 v1, out float3 v2, out float3 v3) {
//     float sign = v1.z >= 0.0f ? 1.0f : -1.0f;
//     float a = -1 / (sign + v1.z);
//     float b = v1.x * v1.y * a;
//     v2 = float3(1 + sign * sqrt(v1.x) * a, sign * b, -sign * v1.x);
//     v3 = float3(b, sign + sqrt(v1.y) * a, -v1.y);
// }
