#pragma once

struct Ray {
    float3 origin;
    float3 direction;
    float pdf; // probability this ray was sampled

    RayDesc desc(float tmin, float tmax) {
        RayDesc desc;
        desc.Origin = origin;
        desc.Direction = direction;
        desc.TMin = tmin;
        desc.TMax = tmax;
        return desc;
    }

    Ray transformed(float3x4 mat) {
        Ray ray;
        ray.origin = mul(mat, float4(origin, 1.0));
        ray.direction = normalize(mul(mat, float4(direction, 0.0)));
        ray.pdf = pdf;
        return ray;
    }
};