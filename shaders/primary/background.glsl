layout(binding = 0, set = 1) uniform sampler2D backgroundSampler;
layout(binding = 1, set = 1, r32f) uniform readonly image2D conditionalPdfs;
layout(binding = 2, set = 1, r32f) uniform readonly image2D conditionalCdfs;
layout(binding = 3, set = 1, r32f) uniform readonly image1D marginalPdf;
layout(binding = 4, set = 1, r32f) uniform readonly image1D marginalCdf;

layout(location = 0) rayPayloadEXT Payload payload;
layout(location = 1) rayPayloadEXT bool inShadow;

float sample2D(vec2 uv, out vec2 result) {
    ivec2 size = imageSize(conditionalCdfs);
    int width = size.x;
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
    float dv = (uv.y - imageLoad(marginalCdf, offset_v).r) / (imageLoad(marginalCdf, offset_v + 1).r - imageLoad(marginalCdf, offset_v).r);
    float pdf_v = imageLoad(marginalPdf, offset_v).r;
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
    float du = (uv.x - imageLoad(conditionalCdfs, ivec2(offset_u, offset_v)).r) / (imageLoad(conditionalCdfs, ivec2(offset_u + 1, offset_v)).r - imageLoad(conditionalCdfs, ivec2(offset_u, offset_v)).r);
    float pdf_u = imageLoad(conditionalPdfs, ivec2(offset_u, offset_v)).r;
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

vec3 estimateBackgroundDirect(Frame frame, vec3 outgoing, Material material, vec2 rand_uv) {
    vec3 dir;
    vec2 uv;
    float pdf = sampleEnv(rand_uv, dir, uv);
    inShadow = true;
    if (dot(payload.normal, dir) > 0.0) { 
        uint flags = gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsOpaqueEXT | gl_RayFlagsSkipClosestHitShaderEXT;
        traceRayEXT(TLAS, flags, 0xFF, 0, 0, 1, payload.point, 0.001, dir, 10000.0, 1);
    }
    if (!inShadow) {
        vec3 frameSunDir = worldToFrame(frame, dir);
        vec3 brdf = f_r(frameSunDir, outgoing, material);
        vec3 color = texture(backgroundSampler, uv).rgb;
        return color * brdf * abs(frameCosTheta(frameSunDir)) / pdf;
    } else {
        return vec3(0.0);
    }
}

vec3 getBackgroundColor(vec3 direction) {
    vec2 uv = vec2(atan(direction.z, direction.x), asin(-direction.y));
    uv /= vec2(2.0 * PI, PI);
    uv += vec2(0.5);
    return texture(backgroundSampler, uv).rgb;
}
