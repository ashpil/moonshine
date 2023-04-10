#pragma once

#include "../utils/random.hlsl"

struct Camera {
    float3 origin;
    float3 lower_left_corner;
    float3 horizontal;
    float3 vertical;
    float3 u, v;
    float lens_radius;

    RayDesc generateRay(float2 uv, float2 rand) {
        float2 sampled_rand = squareToUniformDiskConcentric(rand.xy);
        float2 rd = lens_radius * sampled_rand;
        float3 defocusOffset = u * rd.x + v * rd.y;
        
        RayDesc rayDesc;
        rayDesc.Origin = origin + defocusOffset;
        rayDesc.Direction = normalize(lower_left_corner + uv.x * horizontal + uv.y * vertical - defocusOffset - origin);
        rayDesc.TMin = 0;
        rayDesc.TMax = INFINITY;

        return rayDesc;
    }
};

