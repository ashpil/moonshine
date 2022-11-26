// different than PBRT as in our system y is up
struct Frame {
    float3x3 toFrame;

    float3 worldToFrame(float3 v) {
        return mul(this.toFrame, v);
    }

    float3 frameToWorld(float3 v) {
        return mul(transpose(this.toFrame), v);
    }
};

// takes in a normalized vector, returns a frame where x,y,z are bitangent, normal, and tangent respectively
Frame createFrame(float3 n) {
    float3 t;
    if (abs(n.x) > abs(n.z)) {
        float len = sqrt(n.x * n.x + n.y * n.y);
        t = float3(n.y / len, -n.x / len, 0.0);
    } else {
        float len = sqrt(n.z * n.z + n.y * n.y);
        t = float3(0.0, -n.z / len, n.y / len);
    }

    float3 s = normalize(cross(t, n));

    float3x3 toFrame = { s, n, t };
    Frame frame;
    frame.toFrame = toFrame;
    return frame;
}

float frameCosTheta(float3 v) {
    return v.y;
}

float frameCos2Theta(float3 v) {
    return v.y * v.y;
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
    return (sinTheta == 0.0) ? 0.0 : clamp(v.z / sinTheta, -1.0, 1.0);
}

bool sameHemisphere(float3 v1, float3 v2) {
    return v1.y * v2.y > 0.0;
}

