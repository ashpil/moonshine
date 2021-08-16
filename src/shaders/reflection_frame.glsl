struct Frame {
    mat3 toWorld;
};

// takes in a normalized vector, returns a frame where x,y,z are bitangent, tangent and normal respectively
Frame createFrame(vec3 n) {
    vec3 t;
    if (abs(n.x) > abs(n.y)) {
        float len = sqrt(n.x * n.x + n.z * n.z);
        t = vec3(n.z / len, 0.0, -n.x / len);
    } else {
        float len = sqrt(n.y * n.y + n.z * n.z);
        t = vec3(0.0, n.z / len, -n.y / len);
    }

    vec3 s = normalize(cross(t, n));

    Frame frame;
    frame.toWorld = mat3(s, t, n);
    return frame;
}

vec3 worldToFrame(Frame frame, vec3 v) {
    return transpose(frame.toWorld) * v;
}

vec3 frameToWorld(Frame frame, vec3 v) {
    return frame.toWorld * v;
}

float frameCosTheta(vec3 v) {
    return v.z;
}

float frameCos2Theta(vec3 v) {
    return v.z * v.z;
}

float frameSin2Theta(vec3 v) {
    return max(0.0, 1.0 - frameCos2Theta(v));
}

float frameSinTheta(vec3 v) {
    return sqrt(frameSin2Theta(v));
}

float frameTanTheta(vec3 v) {
    return frameSinTheta(v) / frameCosTheta(v);
}

float frameTan2Theta(vec3 v) {
    return frameSin2Theta(v) / frameCos2Theta(v);
}

float frameCosPhi(vec3 v) {
    float sinTheta = frameSinTheta(v);
    return (sinTheta == 0.0) ? 1.0 : clamp(v.x / sinTheta, -1.0, 1.0);
}

float frameSinPhi(vec3 v) {
    float sinTheta = frameSinTheta(v);
    return (sinTheta == 0.0) ? 0.0 : clamp(v.y / sinTheta, -1.0, 1.0);
}
