struct ClickData {
    int instance_index; // -1 if invalid
    uint geometry_index;
    uint primitive_index;
    float2 barycentrics;
};

[[vk::binding(0, 0)]] RWTexture2D<float4> dStorageImages[];
[[vk::binding(0, 1)]] RWStructuredBuffer<ClickData> click_data;
[[vk::binding(0, 2)]] RaytracingAccelerationStructure TLAS;

#include "camera.hlsl"

struct [raypayload] Payload {
    ClickData click_data : read(caller) : write(closesthit, miss);
};

struct PushConsts {
	Camera camera;
	float2 coords;
    uint outputImage;
};
[[vk::push_constant]] PushConsts pushConsts;

[shader("raygeneration")]
void raygen() {
    float2 uv = pushConsts.coords;
    uv.y -= 1;
    uv.y *= -1;
    Camera camera = pushConsts.camera;
    // make camera have perfect focus
    camera.focus_distance = 1.0f;
    camera.aperture = 0.0f;
    RayDesc ray = pushConsts.camera.generateRay(pushConsts.outputImage, uv, float2(0, 0));

    Payload payload;
    TraceRay(TLAS, RAY_FLAG_FORCE_OPAQUE, 0xFF, 0, 0, 0, ray, payload);

    click_data[0] = payload.click_data;
}

[shader("miss")]
void miss(inout Payload payload) {
    payload.click_data.instance_index = -1;
}

struct Attributes
{
    float2 barycentrics;
};

[shader("closesthit")]
void closesthit(inout Payload payload, in Attributes attribs) {
    payload.click_data.instance_index = InstanceIndex();
    payload.click_data.primitive_index = PrimitiveIndex();
    payload.click_data.geometry_index = GeometryIndex();
    payload.click_data.barycentrics = attribs.barycentrics;
}
