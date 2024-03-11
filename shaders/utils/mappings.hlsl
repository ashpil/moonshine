#pragma once

#include "math.hlsl"

float2 squareToTriangle(float2 square) {
    float a = 1 - sqrt(1 - square.x);
    float b = square.y * sqrt(1 - square.x);
    return float2(a, b);
}

float2 squareToGaussian(float2 square) {
    const float u1 = 1.0 - square.x;
    const float u2 = square.y;
    const float r = sqrt(-2.0 * log(u1));
    const float theta = 2 * PI * u2;
    return r * float2(cos(theta), sin(theta));
}

float2 squareToUniformDiskConcentric(float2 square) {
    float2 uOffset = 2.0 * square - float2(1.0, 1.0);

    if (all(uOffset == float2(0.0, 0.0))) {
        return float2(0.0, 0.0);
    }

    float theta, r;

    if (abs(uOffset.x) > abs(uOffset.y)) {
        r = uOffset.x;
        theta = (PI / 4) * (uOffset.y / uOffset.x);
    } else {
        r = uOffset.y;
        theta = (PI / 2) - (PI / 4) * (uOffset.x / uOffset.y);
    }

    return r * float2(cos(theta), sin(theta));
}

float3 squareToCosineHemisphere(float2 square) {
    float2 d = squareToUniformDiskConcentric(square);
    float z = sqrt(max(0.0, 1.0 - dot(d, d)));

    return float3(d.x, d.y, z);
}

float3 squareToUniformHemisphere(float2 square) {
    float z = square.x;
    float r = sqrt(max(0.0, 1.0 - z * z));
    float phi = 2 * PI * square.y;
    return float3(r * cos(phi), r * sin(phi), z);
}

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

// from PBRTv4 3.8.3 "Equal-Area Mapping"
float3 squareToEqualAreaSphere(float2 square) {
	const float2 uv = 2.0 * square - float2(1.0, 1.0);
	const float2 uvp = abs(uv);

	const float signedDistance = 1.0 - (uvp.x + uvp.y);
	const float d = abs(signedDistance);
	const float r = 1.0 - d;

	const float phi = (r == 0.0 ? 1.0 : (uvp.y - uvp.x) / r + 1.0) * PI / 4.0;
	const float3 signs = sign(float3(uv.x, uv.y, signedDistance));

	return signs * float3(
		cos(phi) * r * sqrt(2.0 - r * r),
		sin(phi) * r * sqrt(2.0 - r * r),
		1.0f - r * r
	);
}

float2 squareToEqualAreaSphereInverse(float3 dir) {
	const float3 xyz = abs(dir);
	const float r = sqrt(1.0 - xyz.z);

	float phi = all(xyz.xy == float2(0.0, 0.0)) ? 0.0 : atan2(min(xyz.x, xyz.y), max(xyz.x, xyz.y)) * 2.0 / PI;
	if (xyz.x < xyz.y) phi = 1.0 - phi;

	float2 uv = float2(r - phi * r, phi * r); 

	if (dir.z < 0) uv = float2(1.0, 1.0) - float2(uv.y, uv.x);

	uv *= sign(dir.xy);

	return (uv + float2(1.0, 1.0)) / 2.0;
}

// selects true with probability p (false otherwise),
// remapping rand back into (0..1)
bool coinFlipRemap(float p, inout float rand) {
    if (rand < p) {
        rand /= p;
        return true;
    } else {
        rand = (rand - p) / (1.0 - p);
        return false;
    }
}

// samples from an alias table, remaps rand
template <class Data, class Entry>
Data sampleAlias(StructuredBuffer<Entry> entries, uint entryCount, uint offset, inout float rand, inout uint idx) {
    float scaled = rand * entryCount;
    idx = uint(scaled);
    rand = frac(scaled);
    
    Entry e = entries[offset + idx];
    if (!coinFlipRemap(e.select, rand)) {
        idx = e.alias;
        e = entries[offset + idx];
    }
    return e.data;
}
