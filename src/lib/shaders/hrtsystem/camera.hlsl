#pragma once

#include "../utils/mappings.hlsl"
#include "../utils/helpers.hlsl"
#include "ray.hlsl"

// in camera space, cameras are oriented:
// * forward along +X
// * right along +Y
// * up along +Z

enum class CameraModel : uint {
    ThinLens,
    Orthographic,
};

struct ThinLens {
    float vfov;
    float aperture;
    float focusDistance;

    // uv is [-aspectRatio, aspectRatio], [-1, 1]
    Ray generateRay(const float2 rand, const float2 uv) {
        const float2 halfViewport = tan(vfov / 2);

        const float3 directionCameraSpaceUnorm = float3(1.0, uv * halfViewport);

        const float2 lens = aperture * squareToUniformDiskConcentric(rand) / 2.0;
        const float3 focus = focusDistance * directionCameraSpaceUnorm;

        Ray ray;
        ray.origin = float3(0.0, lens);
        ray.direction = normalize(focus - ray.origin);

        return ray;
    }
};

struct Orthographic {
    float vscale;

    Ray generateRay(const float2 uv) {
        const float2 halfViewport = vscale;

        Ray ray;
        ray.origin = float3(0.0, uv * halfViewport);
        ray.direction = float3(1, 0, 0);

        return ray;
    }
};

struct Camera {
    row_major float3x4 toWorld;
    CameraModel model;
    ThinLens thinLens;
    Orthographic orthographic;
    float aspect;

    Ray generateRay(const float2 uv, const float2 rand) {
        const float2 uvScaled = (uv * 2 - 1) * float2(aspect, 1);
        const Ray rayCameraSpace = thinLens.generateRay(rand, uvScaled);
        switch (model) {
            case CameraModel::ThinLens: {
                return thinLens.generateRay(rand, uvScaled).transformed(toWorld);
            }
            case CameraModel::Orthographic: {
                return orthographic.generateRay(uvScaled).transformed(toWorld);
            }
        }
    }
};

