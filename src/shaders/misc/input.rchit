#version 460
#extension GL_EXT_ray_tracing : require

layout(location = 0) rayPayloadInEXT int payload;

void main() {
    payload = gl_InstanceID;
}
