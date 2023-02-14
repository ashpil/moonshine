// different than PBRT as in our system y is up
struct Frame {
    float3 n; // normal
    float3 s; // tangent
    float3 t; // bitangent

    // takes in a normalized vector, returns a frame where x,y,z are bitangent, normal, and tangent respectively
    static Frame create(float3 n) {
        float3 t, s;
        coordinateSystem(n, t, s);
        return Frame::create(n, s, t);
    }

    static Frame create(float3 n, float3 s, float3 t) {
        Frame frame;
        frame.n = n;
        frame.s = s;
        frame.t = t;
        return frame;
    }

    Frame inSpace(float4x3 m) {
        float3 n2 = normalize(mul(m, n).xyz);
        float3 s2 = normalize(mul(m, s).xyz);
        float3 t2 = normalize(mul(m, t).xyz);

        return Frame::create(n2, s2, t2);
    }

    float3 worldToFrame(float3 v) {
        float3x3 toFrame = { s, n, t };
        return mul(toFrame, v);
    }

    float3 frameToWorld(float3 v) {
        float3x3 toFrame = { s, n, t };
        return mul(transpose(toFrame), v);
    }

    static float cosTheta(float3 v) {
        return v.y;
    }

    static float cos2Theta(float3 v) {
        return v.y * v.y;
    }

    static float sin2Theta(float3 v) {
        return max(0.0, 1.0 - cos2Theta(v));
    }

    static float sinTheta(float3 v) {
        return sqrt(sin2Theta(v));
    }

    static float tanTheta(float3 v) {
        return sinTheta(v) / cosTheta(v);
    }

    static float tan2Theta(float3 v) {
        return sin2Theta(v) / cos2Theta(v);
    }

    static float cosPhi(float3 v) {
        float sinTheta = Frame::sinTheta(v);
        return (sinTheta == 0.0) ? 1.0 : clamp(v.x / sinTheta, -1.0, 1.0);
    }

    static float sinPhi(float3 v) {
        float sinTheta = Frame::sinTheta(v);
        return (sinTheta == 0.0) ? 0.0 : clamp(v.z / sinTheta, -1.0, 1.0);
    }

    static bool sameHemisphere(float3 v1, float3 v2) {
        return v1.y * v2.y > 0.0;
    }
};

