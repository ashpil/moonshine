#version 460
#extension GL_EXT_ray_tracing : require

struct ClickData {
    int instance_index;
    uint primitive_index;
    vec2 barycentrics;
};

hitAttributeEXT vec2 barycentrics;

layout(location = 0) rayPayloadInEXT ClickData payload;

void main() {
    payload.instance_index = gl_InstanceID;
    payload.primitive_index = gl_PrimitiveID;
    payload.barycentrics = barycentrics;
}
