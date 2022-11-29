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
    LightSample sample(float3 positionWs, float2 square);
    float pdf(float3 positionWs, float3 dirWs);
    float3 eval(float3 positionWs, float3 dirWs);
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

    LightSample sample(float3 positionWs, float2 square) {
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

    float pdf(float3 positionWs, float3 dirWs) {
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

    float3 eval(float3 positionWs, float3 dirWs) {
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

// estimates direct lighting from light + brdf via MIS
// TODO: is it better to trace two rays as currently or is a one-ray approach preferable?
template <class Light, class Material>
float3 estimateDirect(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float4 rand) {
    float3 directLighting = float3(0.0, 0.0, 0.0);

    // sample light
    {
        LightSample lightSample = light.sample(positionWs, rand.xy);
        
        // holy fuck spirv/nvidia why are you like this
        // for some reason on nvidia only if i call this before the raycast below i get super weird artifacts
        // took two hours to figure it out ugh
        // float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);

        if (dot(frame.toFrame[1], lightSample.dirWs) > 0.0) {
            RayDesc ray;
            ray.Origin = positionWs;
            ray.Direction = lightSample.dirWs;
            ray.TMin = 0.001;
            ray.TMax = 10000.0;

            if (!shadowed(ray)) {
                float3 lightDirFs = frame.worldToFrame(lightSample.dirWs); 
                float scatteringPdf = material.pdf(lightDirFs, outgoingDirFs);
                if (scatteringPdf > 0) {
                    float3 brdf = material.eval(lightDirFs, outgoingDirFs);
                    float weight = powerHeuristic(1, lightSample.pdf, 1, scatteringPdf);
                    directLighting += lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
                }
            }
        }
    }

    // sample material
    {
        MaterialSample materialSample = material.sample(outgoingDirFs, rand.zw);

        if (Frame::cosTheta(materialSample.dirFs) > 0.0) {
            float3 brdfDirWs = frame.frameToWorld(materialSample.dirFs);

            RayDesc ray;
            ray.Origin = positionWs;
            ray.Direction = brdfDirWs;
            ray.TMin = 0.001;
            ray.TMax = 10000.0;

            if (!shadowed(ray)) {
                float lightPdf = light.pdf(positionWs, brdfDirWs);
                float weight = powerHeuristic(1, materialSample.pdf, 1, lightPdf);
                float3 li = light.eval(positionWs, brdfDirWs);
                float3 brdf = material.eval(materialSample.dirFs, outgoingDirFs);
                directLighting += li * brdf * weight * abs(Frame::cosTheta(materialSample.dirFs)) / materialSample.pdf;
            }
        }
    }

    return directLighting;
}
