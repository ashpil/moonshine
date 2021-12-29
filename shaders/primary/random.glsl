uint stepRNG(uint rngState) {
    return rngState * 747796405 + 1;
}

float stepAndOutputRNGFloat(inout uint rngState) {
    rngState = stepRNG(rngState);
    uint word = ((rngState >> ((rngState >> 28) + 4)) ^ rngState) * 277803737;
    word = (word >> 22) ^ word;
    return float(word) / 4294967295.0;
}

vec3 randomDirection(inout uint rngState) {
    const float theta = 2 * PI * stepAndOutputRNGFloat(rngState);
    const float u = 2.0 * stepAndOutputRNGFloat(rngState) - 1.0;
    const float r = sqrt(1.0 - u * u);
    return vec3(r * cos(theta), r * sin(theta), u);
}

vec2 randomGaussian(inout uint rngState) {
    const float u1 = max(1e-38, stepAndOutputRNGFloat(rngState));
    const float u2 = stepAndOutputRNGFloat(rngState);
    const float r = sqrt(-2.0 * log(u1));
    const float theta = 2 * PI * u2;
    return r * vec2(cos(theta), sin(theta));
}

vec2 squareToUniformDiskConcentric(vec2 square) {
    float r1 = 2.0 * square.x - 1.0;
    float r2 = 2.0 * square.y - 1.0;
    vec2 uOffset = 2.0 * square - vec2(1.0);

    if (uOffset == vec2(0.0)) {
        return vec2(0.0);
    }

    float theta, r;

    if (abs(uOffset.x) > abs(uOffset.y)) {
        r = uOffset.x;
        theta = (PI / 4) * (uOffset.y / uOffset.x);
    } else {
        r = uOffset.y;
        theta = (PI / 2) - (PI / 4) * (uOffset.x / uOffset.y);
    }

    return r * vec2(cos(theta), sin(theta));
}

vec3 squareToCosineHemisphere(vec2 square) {
    vec2 d = squareToUniformDiskConcentric(square);
    float z = sqrt(max(0.0, 1.0 - d.x * d.x - d.y * d.y));

    return vec3(d.x, d.y, z);
}

vec3 squareToUniformHemisphere(vec2 square) {
    float z = square.x;
    float r = sqrt(max(0.0, 1.0 - z * z));
    float phi = 2 * PI * square.y;
    return vec3(r * cos(phi), r * sin(phi), z);
}
