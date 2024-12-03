#pragma once

#include "../utils/mappings.hlsl"
#include "../utils/helpers.hlsl"
#include "ray.hlsl"

// in camera space, cameras are oriented:
// * forward along +X
// * right along +Y
// * up along +Z

struct ThinLens {
    float vfov;
    float aspect;
    float aperture;
    float focusDistance;

    Ray generateRay(const float2 rand, const float2 uv) {
        const float2 uvNDC = uv * 2 - 1;

        const float halfViewportHeight = tan(vfov / 2);
        const float halfViewportWidth = aspect * halfViewportHeight;
        const float2 halfViewport = float2(halfViewportWidth, halfViewportHeight);

        const float3 directionCameraSpaceUnorm = float3(1.0, uvNDC * halfViewport);

        const float2 lens = aperture * squareToUniformDiskConcentric(rand) / 2.0;
        const float3 focus = focusDistance * directionCameraSpaceUnorm;

        Ray ray;
        ray.origin = float3(0.0, lens);
        ray.direction = normalize(focus - ray.origin);
        ray.pdf = 1.#INF;

        return ray;
    }
};

struct Camera {
    row_major float3x4 toWorld;
    float vfov;
    float aperture;
    float focusDistance;
    float aspect;

    Ray generateRay(const float2 uv, const float2 rand) {
        const ThinLens thinLens = {vfov, aspect, aperture, focusDistance};
        const Ray rayCameraSpace = thinLens.generateRay(rand, uv);

        return rayCameraSpace.transformed(toWorld);
    }
};

