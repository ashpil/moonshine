#include "../../lib/hrtsystem/shaders/camera.hlsl"
#include "../../lib/hrtsystem/shaders/intersection.hlsl"

[[vk::binding(0, 0)]] RaytracingAccelerationStructure TLAS;
[[vk::binding(1, 0)]] RWTexture2D<float4> dOutputImage;
[[vk::binding(2, 0)]] RWStructuredBuffer<Intersection> click_data;

struct PushConsts {
	Camera camera;
	float2 coords;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(1, 1, 1)]
void main() {
    Camera camera = pushConsts.camera;
    // make camera have perfect focus
    camera.thinLens.focusDistance = 1.0f;
    camera.thinLens.aperture = 0.0f;
    Ray ray = pushConsts.camera.generateRay(pushConsts.coords, float2(0, 0));

    click_data[0] = Intersection::find(TLAS, ray);
}
