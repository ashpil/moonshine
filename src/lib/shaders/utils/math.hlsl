#pragma once

static const float PI = 3.14159265;
static const float EPSILON = 0.000000119;
static const uint MAX_UINT = 0xFFFFFFFF;

float3 vectorToColor(float3 v) {
    return (v + 1.0) / 2.0;
}

float atanh(float x) {
    return log((1 + x) / (1 - x)) / 2;
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

// https://www.nu42.com/2015/03/how-you-average-numbers.html
float3 accumulate(const float3 priorAverage, const float3 newSample, const uint sampleCount) {
    return priorAverage + (newSample - priorAverage) / (sampleCount + 1);
}

void coordinateSystem(float3 v1, out float3 v2, out float3 v3) {
    if (abs(v1.x) > abs(v1.y)) {
        v2 = float3(-v1.z, 0.0, v1.x) / sqrt(v1.x * v1.x + v1.z * v1.z);
    } else {
        v2 = float3(0.0, v1.z, -v1.y) / sqrt(v1.y * v1.y + v1.z * v1.z);
    }

    v3 = cross(v2, v1);
}

uint log2Int(const uint x) {
    return firstbithigh(x);
}

uint log2IntCeil(const uint x) {
    if (x == 1) return 0;
    return log2Int(x - 1) + 1;
}

// TODO: switch to this when figure it why it doesn't work
// void coordinateSystem(float3 v1, out float3 v2, out float3 v3) {
//     float sign = v1.z >= 0.0f ? 1.0f : -1.0f;
//     float a = -1 / (sign + v1.z);
//     float b = v1.x * v1.y * a;
//     v2 = float3(1 + sign * sqrt(v1.x) * a, sign * b, -sign * v1.x);
//     v3 = float3(b, sign + sqrt(v1.y) * a, -v1.y);
// }
