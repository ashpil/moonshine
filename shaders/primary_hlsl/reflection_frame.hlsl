struct Frame {
    float3x3 toFrame;
};

// takes in a normalized vector, returns a frame where x,y,z are bitangent, tangent and normal respectively
Frame createFrame(float3 n) {
    float3 t;
    if (abs(n.x) > abs(n.y)) {
        float len = sqrt(n.x * n.x + n.z * n.z);
        t = float3(n.z / len, 0.0, -n.x / len);
    } else {
        float len = sqrt(n.y * n.y + n.z * n.z);
        t = float3(0.0, n.z / len, -n.y / len);
    }

    float3 s = normalize(cross(t, n));

    float3x3 toFrame = { s, t, n };
    Frame frame;
    frame.toFrame = toFrame;
    return frame;
}

float3 worldToFrame(Frame frame, float3 v) {
    return mul(frame.toFrame, v);
}

float3 frameToWorld(Frame frame, float3 v) {
    return mul(transpose(frame.toFrame), v);
}

float frameCosTheta(float3 v) {
    return v.z;
}

float frameCos2Theta(float3 v) {
    return v.z * v.z;
}

float frameSin2Theta(float3 v) {
    return max(0.0, 1.0 - frameCos2Theta(v));
}

float frameSinTheta(float3 v) {
    return sqrt(frameSin2Theta(v));
}

float frameTanTheta(float3 v) {
    return frameSinTheta(v) / frameCosTheta(v);
}

float frameTan2Theta(float3 v) {
    return frameSin2Theta(v) / frameCos2Theta(v);
}

float frameCosPhi(float3 v) {
    float sinTheta = frameSinTheta(v);
    return (sinTheta == 0.0) ? 1.0 : clamp(v.x / sinTheta, -1.0, 1.0);
}

float frameSinPhi(float3 v) {
    float sinTheta = frameSinTheta(v);
    return (sinTheta == 0.0) ? 0.0 : clamp(v.y / sinTheta, -1.0, 1.0);
}
