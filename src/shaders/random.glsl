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

    float phi, r;

    if (r1 == 0 && r2 == 0) {
        r = phi = 0;
    } else if (r1 * r1 > r2 * r2) {
        r = r1;
        phi = PI / 4.0 * r2 / r1;
    } else {
        r = r2;
        phi = (PI / 2.0) - (r1 / r2) * (PI / 4.0);
    }

    float cosPhi = cos(phi);
    float sinPhi = sin(phi);

    return vec2(r * cosPhi, r * sinPhi);
}

vec3 squareToCosineHemisphere(vec2 square) {
    vec2 p = squareToUniformDiskConcentric(square);
    float z = sqrt(max(1.0 - p.x * p.x - p.y * p.y, 0.00001));

    return vec3(p.x, p.y, z);
}