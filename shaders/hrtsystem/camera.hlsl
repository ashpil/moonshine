#pragma once

#include "../utils/random.hlsl"

struct Camera {
    float3 origin;
    float3 forward;
    float3 up;
    float vfov;
    float aperture;
    float focus_distance;

    RayDesc generateRay(RWTexture2D<float4> outputImage, float2 uv, float2 rand) {
        uint2 sensor_size;
        outputImage.GetDimensions(sensor_size.x, sensor_size.y);
        float aspect = float(sensor_size.x) / float(sensor_size.y);

        float3 w = forward * -1.0f;
        float3 u = normalize(cross(up, w));
        float3 v = cross(w, u);

        float h = tan(vfov / 2.0f);
        float viewport_height = 2.0 * h * focus_distance;
        float viewport_width = aspect * viewport_height;

        float3 horizontal = u * viewport_width;
        float3 vertical = v * viewport_height;

        float3 lower_left_corner = origin - (horizontal / 2.0f) - (vertical / 2.0f) - (w * focus_distance);

        float2 sampled_rand = squareToUniformDiskConcentric(rand.xy);
        float2 rd = aperture * sampled_rand / 2.0f;
        float3 defocusOffset = u * rd.x + v * rd.y;
        
        RayDesc rayDesc;
        rayDesc.Origin = origin + defocusOffset;
        rayDesc.Direction = normalize(lower_left_corner + uv.x * horizontal + uv.y * vertical - defocusOffset - origin);
        rayDesc.TMin = 0;
        rayDesc.TMax = INFINITY;

        return rayDesc;
    }
};

