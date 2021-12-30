layout(binding = 0, set = 1) uniform sampler2D backgroundSampler;
layout(binding = 1, set = 1, r32f) uniform readonly image2D conditionalPdfsIntegrals;
layout(binding = 2, set = 1, r32f) uniform readonly image2D conditionalCdfs;
layout(binding = 3, set = 1, r32f) uniform readonly image1D marginalPdfIntegral;
layout(binding = 4, set = 1, r32f) uniform readonly image1D marginalCdf;

layout(location = 0) rayPayloadEXT Payload payload;
layout(location = 1) rayPayloadEXT bool inShadow;

float sample2D(vec2 uv, out vec2 result) {
    ivec2 size = imageSize(conditionalCdfs);
    int width = size.x - 1;
    int height = size.y;

    // get y
    int first = 0;
    int len = height;

    while (len > 0) {
        int halfs = len >> 1;
        int middle = first + halfs;
        
        if (imageLoad(marginalCdf, middle).r <= uv.y) {
            first = middle + 1;
            len -= halfs + 1;
        } else {
            len = halfs;
        }
    }

    int offset_v = clamp(first - 1, 0, height - 2);
    float valv = imageLoad(marginalCdf, offset_v).r;
    float dv = (uv.y - valv) / (imageLoad(marginalCdf, offset_v + 1).r - valv);
    float pdf_v = imageLoad(marginalPdfIntegral, offset_v).r / imageLoad(marginalPdfIntegral, height).r;
    result.y = (offset_v + dv) / height;

    // get x
    first = 0;
    len = width;

    while (len > 0) {
        int halfs = len >> 1;
        int middle = first + halfs;
        
        if (imageLoad(conditionalCdfs, ivec2(middle, offset_v)).r <= uv.x) {
            first = middle + 1;
            len -= halfs + 1;
        } else {
            len = halfs;
        }
    }
    int offset_u = clamp(first - 1, 0, width - 2);
    float valu = imageLoad(conditionalCdfs, ivec2(offset_u, offset_v)).r;
    float du = (uv.x - valu) / (imageLoad(conditionalCdfs, ivec2(offset_u + 1, offset_v)).r - valu);
    float pdf_u = imageLoad(conditionalPdfsIntegrals, ivec2(offset_u, offset_v)).r / imageLoad(conditionalPdfsIntegrals, ivec2(width, offset_v)).r;
    result.x = (offset_u + du) / width;

    return pdf_v * pdf_u;
}

float sampleEnv(vec2 rand_uv, out vec3 dir, inout vec2 uv) {
    float mapPdf = sample2D(rand_uv, uv);
    uv.y -= 1;
    uv.y *= -1;

    float theta = uv.x * 2.0 * PI;
    float phi = uv.y * PI;

    uv.y -= 1;
    uv.y *= -1;

    float cosTheta = cos(theta);
    float sinTheta = sin(theta);
    float sinPhi = sin(phi);
    float cosPhi = cos(phi);
    
    dir = vec3(cosPhi * cosTheta, sinPhi, cosPhi * sinTheta);
    return mapPdf / (2.0 * PI * PI * sinPhi);
}

float backgroundPDF(vec3 w_i) {
    ivec2 size = imageSize(conditionalCdfs);
    int width = size.x - 1;
    int height = size.y;

    vec2 theta_phi = vec2(atan(w_i.z, w_i.x), asin(w_i.y));
    float sin_phi = sin(theta_phi.y);
    theta_phi /= vec2(2.0 * PI, PI);

    vec2 uv = theta_phi + vec2(0.5, 0.0);
    ivec2 coords = clamp(ivec2(uv * vec2(width, height)), ivec2(0), ivec2(width - 1, height - 1));

    float pdf = imageLoad(conditionalPdfsIntegrals, coords).r / imageLoad(marginalPdfIntegral, height).r;
    return pdf / (2.0 * PI * PI * sin_phi);
}

vec3 getBackgroundColor(vec3 direction) {
    vec2 uv = vec2(atan(direction.z, direction.x), asin(-direction.y));
    uv /= vec2(2.0 * PI, PI);
    uv += vec2(0.5);
    return texture(backgroundSampler, uv).rgb;
}

float powerHeuristic(uint numf, float fPdf, uint numg, float gPdf) {
    float f = numf * fPdf;
    float g = numg * gPdf;

    float f2 = f * f;
    return (f2 / (f2 + g * g));
}

vec3 estimateBackgroundDirect(Frame frame, vec3 outgoing, Material material, vec4 rand) {
    vec3 directLighting = vec3(0.0);

    float scatteringPdf;

    // sample env
    vec3 dir;
    vec2 uv;
    float lightPdf = sampleEnv(rand.xy, dir, uv);

    inShadow = true;
    if (dot(payload.normal, dir) > 0.0) { 
        uint flags = gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsOpaqueEXT | gl_RayFlagsSkipClosestHitShaderEXT;
        traceRayEXT(TLAS, flags, 0xFF, 0, 0, 1, payload.point, 0.001, dir, 10000.0, 1);
    }
    if (!inShadow) {
        vec3 frameSunDir = worldToFrame(frame, dir);
        scatteringPdf = scatteringPDF(frameSunDir, outgoing, material);
        if (scatteringPdf > 0) {
            vec3 frameSunDir = worldToFrame(frame, dir);
            vec3 brdf = f_r(frameSunDir, outgoing, material);
            vec3 li = texture(backgroundSampler, uv).rgb;
            float weight = powerHeuristic(1, lightPdf, 1, scatteringPdf);
            directLighting += li * brdf * abs(frameCosTheta(frameSunDir)) * weight / lightPdf;
        }
    }

    // sample material
    dir = sample_f_r(outgoing, material, scatteringPdf, rand.zw);
    inShadow = true;
    vec3 dir_world = frameToWorld(frame, dir);
    if (dot(payload.normal, dir_world) > 0.0) { 
        uint flags = gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsOpaqueEXT | gl_RayFlagsSkipClosestHitShaderEXT;
        traceRayEXT(TLAS, flags, 0xFF, 0, 0, 1, payload.point, 0.001, dir_world, 10000.0, 1);
    }
    if (!inShadow) {
        lightPdf = backgroundPDF(dir_world);
        float weight = powerHeuristic(1, scatteringPdf, 1, lightPdf);
        vec3 li = min(getBackgroundColor(dir_world), 1.0);
        vec3 brdf = f_r(dir, outgoing, material);
        directLighting += li * brdf * weight * abs(frameCosTheta(dir)) / scatteringPdf;
    }

    return directLighting;
}
