Texture2D<float3> backgroundTexture : register(t0, space1);
SamplerState backgroundSampler : register(s0, space1);

RWTexture2D<float> conditionalPdfsIntegrals : register(u1, space1);
RWTexture2D<float> conditionalCdfs : register(u2, space1);

RWTexture1D<float> marginalPdfIntegral : register(u3, space1);
RWTexture1D<float> marginalCdf : register(u4, space1);


struct [raypayload] ShadowPayload {
    bool inShadow : read(caller) : write(miss);
};

float sample2D(float2 uv, out float2 result) {
    uint2 size;
    conditionalCdfs.GetDimensions(size.x, size.y);
    int width = size.x - 1;
    int height = size.y;

    // get y
    int first = 0;
    int len = height;

    while (len > 0) {
        int halfs = len >> 1;
        int middle = first + halfs;
        
        if (marginalCdf.Load(middle) <= uv.y) {
            first = middle + 1;
            len -= halfs + 1;
        } else {
            len = halfs;
        }
    }

    int offset_v = clamp(first - 1, 0, height - 2);
    float valv = marginalCdf[offset_v];
    float dv = (uv.y - valv) / (marginalCdf[offset_v + 1] - valv);
    float pdf_v = marginalPdfIntegral[offset_v] / marginalPdfIntegral[height];
    result.y = (offset_v + dv) / height;

    // get x
    first = 0;
    len = width;

    while (len > 0) {
        int halfs = len >> 1;
        int middle = first + halfs;
        
        if (conditionalCdfs[int2(middle, offset_v)] <= uv.x) {
            first = middle + 1;
            len -= halfs + 1;
        } else {
            len = halfs;
        }
    }
    int offset_u = clamp(first - 1, 0, width - 2);
    float valu = conditionalCdfs[int2(offset_u, offset_v)];
    float du = (uv.x - valu) / (conditionalCdfs[int2(offset_u + 1, offset_v)] - valu);
    float pdf_u = conditionalPdfsIntegrals[int2(offset_u, offset_v)] / conditionalPdfsIntegrals[int2(width, offset_v)];
    result.x = (offset_u + du) / width;

    return pdf_v * pdf_u;
}

float sampleEnv(float2 rand_uv, out float3 dir, inout float2 uv) {
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
    
    dir = float3(cosPhi * cosTheta, sinPhi, cosPhi * sinTheta);
    return mapPdf / (2.0 * PI * PI * sinPhi);
}

float backgroundPDF(float3 w_i) {
    uint2 size;
    conditionalCdfs.GetDimensions(size.x, size.y);
    int width = size.x - 1;
    int height = size.y;

    float2 theta_phi = float2(atan2(w_i.z, w_i.x), asin(w_i.y));
    float sin_phi = sin(theta_phi.y);
    theta_phi /= float2(2.0 * PI, PI);

    float2 uv = theta_phi + float2(0.5, 0.0);
    uint2 coords = clamp(uint2(uv * float2(width, height)), uint2(0, 0), uint2(width - 1, height - 1));

    float pdf = conditionalPdfsIntegrals[coords] / marginalPdfIntegral[height];
    return pdf / (2.0 * PI * PI * sin_phi);
}

float3 getBackgroundColor(float3 direction) {
    float2 uv = float2(atan2(direction.z, direction.x), asin(-direction.y));
    uv /= float2(2.0 * PI, PI);
    uv += float2(0.5, 0.5);
    return backgroundTexture.SampleLevel(backgroundSampler, uv, 0);
}

float powerHeuristic(uint numf, float fPdf, uint numg, float gPdf) {
    float f = numf * fPdf;
    float g = numg * gPdf;

    float f2 = f * f;
    return (f2 / (f2 + g * g));
}

float3 estimateBackgroundDirect(Frame frame, float3 outgoing, Material material, float4 rand, Payload payload) {
    const uint shadowTraceFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;
    float3 directLighting = float3(0.0, 0.0, 0.0);
    // TODO: is it correct to trace two rays here?
    float scatteringPdf;

    // sample env
    float3 dir;
    float2 uv;
    float lightPdf = sampleEnv(rand.xy, dir, uv);

    ShadowPayload shadowPayload;
    shadowPayload.inShadow = true;

    if (dot(payload.normal, dir) > 0.0) { 

        RayDesc ray;
        ray.Origin = payload.position;
        ray.Direction = dir;
        ray.TMin = 0.001;
        ray.TMax = 10000.0;
        TraceRay(TLAS, shadowTraceFlags, 0xFF, 0, 0, 1, ray, shadowPayload);
    }
    if (!shadowPayload.inShadow) {
        float3 frameSunDir = frame.worldToFrame(dir);
        scatteringPdf = material.pdf(frameSunDir, outgoing);
        if (scatteringPdf > 0) {
            float3 frameSunDir = frame.worldToFrame(dir);
            float3 brdf = material.f_r(frameSunDir, outgoing);
            float3 li = backgroundTexture.SampleLevel(backgroundSampler, uv, 0);
            float weight = powerHeuristic(1, lightPdf, 1, scatteringPdf);
            directLighting += li * brdf * abs(frameCosTheta(frameSunDir)) * weight / lightPdf;
        }
    }

    // sample material
    dir = material.sample(outgoing, scatteringPdf, rand.zw);
    shadowPayload.inShadow = true;
    float3 dir_world = frame.frameToWorld(dir);
    if (dot(payload.normal, dir_world) > 0.0) { 
        RayDesc ray;
        ray.Origin = payload.position;
        ray.Direction = dir_world;
        ray.TMin = 0.001;
        ray.TMax = 10000.0;
        TraceRay(TLAS, shadowTraceFlags, 0xFF, 0, 0, 1, ray, shadowPayload);
    }
    if (!shadowPayload.inShadow) {
        lightPdf = backgroundPDF(dir_world);
        float weight = powerHeuristic(1, scatteringPdf, 1, lightPdf);
        float3 li = min(getBackgroundColor(dir_world), 1.0);
        float3 brdf = material.f_r(dir, outgoing);
        directLighting += li * brdf * weight * abs(frameCosTheta(dir)) / scatteringPdf;
    }

    return directLighting;
}
