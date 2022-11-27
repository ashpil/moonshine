Texture2D<float3> g_backgroundTexture : register(t0, space1);
SamplerState g_backgroundSampler : register(s0, space1);

RWTexture2D<float> g_conditionalPdfsIntegrals : register(u1, space1);
RWTexture2D<float> g_conditionalCdfs : register(u2, space1);

RWTexture1D<float> g_marginalPdfIntegral : register(u3, space1);
RWTexture1D<float> g_marginalCdf : register(u4, space1);

struct [raypayload] ShadowPayload {
    bool inShadow : read(caller) : write(miss);
};

// traces a shadow ray, returning whether it hit geometry
bool shadowed(RayDesc ray) {
    const uint shadowTraceFlags = RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_FORCE_OPAQUE | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER;

    ShadowPayload payload;
    payload.inShadow = true;
    TraceRay(TLAS, shadowTraceFlags, 0xFF, 0, 0, 1, ray, payload);
    return payload.inShadow;
}

struct LightSample {
    float3 dirWs;
    float3 radiance;
    float pdf;
};

interface Light {
    LightSample sample(float2 square);
    float pdf(float3 dirWs);
    float3 eval(float3 dirWs);
};

struct EnvMap : Light {
    Texture2D<float3> texture;
    SamplerState sampler;

    RWTexture2D<float> conditionalPdfsIntegrals;
    RWTexture2D<float> conditionalCdfs;

    RWTexture1D<float> marginalPdfIntegral;
    RWTexture1D<float> marginalCdf;

    static EnvMap create() {
        EnvMap map;

        map.texture = g_backgroundTexture;
        map.sampler = g_backgroundSampler;
        map.conditionalPdfsIntegrals = g_conditionalPdfsIntegrals;
        map.conditionalCdfs = g_conditionalCdfs;
        map.marginalPdfIntegral = g_marginalPdfIntegral;
        map.marginalCdf = g_marginalCdf;

        return map;
    }

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

    LightSample sample(float2 square) {
        float2 uv;
        float mapPdf = sample2D(square, uv);

        float phi = uv.x * 2.0 * PI;
        float theta = uv.y * PI;

        float cosTheta = cos(theta);
        
        LightSample lightSample;
        lightSample.pdf = mapPdf / (2.0 * PI * PI * cosTheta);
        lightSample.radiance = texture.SampleLevel(sampler, uv, 0);
        lightSample.dirWs = sphericalToCartesian(sin(theta), cosTheta, phi);
        return lightSample;
    }

    float pdf(float3 dirWs) {
        uint2 size;
        conditionalCdfs.GetDimensions(size.x, size.y);
        int width = size.x - 1;
        int height = size.y;

        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);

        uint2 coords = clamp(uint2(uv * float2(width, height)), uint2(0, 0), uint2(width - 1, height - 1));

        float pdf = conditionalPdfsIntegrals[coords] / marginalPdfIntegral[height];
        return pdf / (2.0 * PI * PI * cos(phiTheta.y));
    }

    float3 eval(float3 dirWs) {
        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);
        return texture.SampleLevel(sampler, uv, 0);
    }
};

float powerHeuristic(uint numf, float fPdf, uint numg, float gPdf) {
    float f = numf * fPdf;
    float g = numg * gPdf;

    float f2 = f * f;
    return (f2 / (f2 + g * g));
}

// estimates lighting from environment map using light + brdf MIS
// TODO: is it better to trace two rays as currently or is a one-ray approach preferable?
float3 estimateBackgroundDirect(EnvMap background, Frame frame, float3 outgoing, StandardPBR material, float4 rand, Payload payload) {
    float3 directLighting = float3(0.0, 0.0, 0.0);

    // sample light
    {
        LightSample lightSample = background.sample(rand.xy);

        if (dot(payload.normal, lightSample.dirWs) > 0.0) { 
            RayDesc ray;
            ray.Origin = payload.position;
            ray.Direction = lightSample.dirWs;
            ray.TMin = 0.001;
            ray.TMax = 10000.0;

            if (!shadowed(ray)) {
                float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);
                float scatteringPdf = material.pdf(lightDirFs, outgoing);
                if (scatteringPdf > 0) {
                    float3 brdf = material.eval(lightDirFs, outgoing);
                    float weight = powerHeuristic(1, lightSample.pdf, 1, scatteringPdf);
                    directLighting += lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
                }
            }
        }
    }

    // sample material
    {
        float scatteringPdf;
        float3 brdfDirFs = material.sample(outgoing, scatteringPdf, rand.zw);

        if (Frame::cosTheta(brdfDirFs) > 0.0) {
            float3 brdfDirWs = frame.frameToWorld(brdfDirFs);

            RayDesc ray;
            ray.Origin = payload.position;
            ray.Direction = brdfDirWs;
            ray.TMin = 0.001;
            ray.TMax = 10000.0;

            if (!shadowed(ray)) {
                float lightPdf = background.pdf(brdfDirWs);
                float weight = powerHeuristic(1, scatteringPdf, 1, lightPdf);
                float3 li = background.eval(brdfDirWs);
                float3 brdf = material.eval(brdfDirFs, outgoing);
                directLighting += li * brdf * weight * abs(Frame::cosTheta(brdfDirFs)) / scatteringPdf;
            }
        }
    }

    return directLighting;
}
