struct LightSample {
    float4 dirWs; // w is distance
    float3 radiance;
    float pdf;
};

interface Light {
    LightSample sample(float3 positionWs, float4 square);
    float pdf(float3 positionWs, float3 dirWs);
    float3 eval(float3 positionWs, float3 dirWs);
};

struct EnvMap : Light {
    static EnvMap create() {
        EnvMap map;
        return map;
    }

    float sample2D(float2 uv, out float2 result) {
        uint2 size;
        dConditionalCdfs.GetDimensions(size.x, size.y);
        int width = size.x - 1;
        int height = size.y;

        // get y
        int first = 0;
        int len = height;

        while (len > 0) {
            int halfs = len >> 1;
            int middle = first + halfs;
            
            if (dMarginalCdf.Load(middle) <= uv.y) {
                first = middle + 1;
                len -= halfs + 1;
            } else {
                len = halfs;
            }
        }

        int offset_v = clamp(first - 1, 0, height - 2);
        float valv = dMarginalCdf[offset_v];
        float dv = (uv.y - valv) / (dMarginalCdf[offset_v + 1] - valv);
        float pdf_v = dMarginalPdfIntegral[offset_v] / dMarginalPdfIntegral[height];
        result.y = (offset_v + dv) / height;

        // get x
        first = 0;
        len = width;

        while (len > 0) {
            int halfs = len >> 1;
            int middle = first + halfs;
            
            if (dConditionalCdfs[int2(middle, offset_v)] <= uv.x) {
                first = middle + 1;
                len -= halfs + 1;
            } else {
                len = halfs;
            }
        }
        int offset_u = clamp(first - 1, 0, width - 2);
        float valu = dConditionalCdfs[int2(offset_u, offset_v)];
        float du = (uv.x - valu) / (dConditionalCdfs[int2(offset_u + 1, offset_v)] - valu);
        float pdf_u = dConditionalPdfsIntegrals[int2(offset_u, offset_v)] / dConditionalPdfsIntegrals[int2(width, offset_v)];
        result.x = (offset_u + du) / width;

        return pdf_v * pdf_u;
    }

    LightSample sample(float3 positionWs, float4 rand) {
        float2 uv;
        float pdf2d = sample2D(rand.xy, uv);

        float phi = uv.x * 2.0 * PI;
        float theta = uv.y * PI;

        float sinTheta = sin(theta);
        
        LightSample lightSample;
        lightSample.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sinTheta) : 0.0;
        lightSample.radiance = dBackgroundTexture.SampleLevel(dBackgroundSampler, uv, 0);
        lightSample.dirWs = float4(sphericalToCartesian(sinTheta, cos(theta), phi), 1000000.0);
        return lightSample;
    }

    float pdf(float3 positionWs, float3 dirWs) {
        uint2 size;
        dConditionalCdfs.GetDimensions(size.x, size.y);
        int width = size.x - 1;
        int height = size.y;

        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);

        uint2 coords = clamp(uint2(uv * float2(width, height)), uint2(0, 0), uint2(width - 1, height - 1));

        float pdf2d = dConditionalPdfsIntegrals[coords] / dMarginalPdfIntegral[height];
        float sinTheta = sin(phiTheta.y);
        return sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sin(phiTheta.y)) : 0.0;
    }

    float3 eval(float3 positionWs, float3 dirWs) {
        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);
        return dBackgroundTexture.SampleLevel(dBackgroundSampler, uv, 0);
    }
};

// all mesh lights in scene
struct MeshLights : Light {
    static MeshLights create() {
        MeshLights map;
        return map;
    }

    LightSample sample(float3 positionWs, float4 rand) {
        LightSample lightSample;
        uint emitterCount = dEmitterAliasTable[0].alias;
        float sum = dEmitterAliasTable[0].weight;
        if (emitterCount != 0) {
            // find relevant entry
            uint x = rand.x * emitterCount;
            AliasEntry entry = dEmitterAliasTable[x + 1];
            if (!coinFlipRemap(entry.weight, rand.y)) {
                entry = dEmitterAliasTable[entry.alias + 1];
            }

            // compute information about it
            uint instanceID = dInstances[entry.instanceIndex].instanceID();

            float2 barycentrics = squareToTriangle(rand.zw);
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(entry.instanceIndex, entry.geometryIndex, entry.primitiveIndex, barycentrics).inWorld(entry.instanceIndex);

            float3 emissive = dMaterialTextures[NonUniformResourceIndex(5 * materialIdx(instanceID, entry.geometryIndex) + 3)].SampleLevel(dTextureSampler, attrs.texcoord, 0).rgb;

            float3 samplePositionToEmitterPositionWs = attrs.position - positionWs;
            float r2 = dot(samplePositionToEmitterPositionWs, samplePositionToEmitterPositionWs);
            float r = sqrt(r2);
            lightSample.radiance = emissive;
            lightSample.dirWs = float4(samplePositionToEmitterPositionWs / r, r);

            // pdf in solid angle measure
            lightSample.pdf = r2 / (abs(dot(-lightSample.dirWs.xyz, attrs.normal)) * sum);
        } else {
            lightSample.pdf = 0.0;
        }
        return lightSample;
    }

    float pdf(float3 positionWs, float3 dirWs) {
        return 0.0; // TODO get area
    }

    float3 eval(float3 positionWs, float3 dirWs) {
        return 0.0; // TODO
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
float3 estimateDirectMIS(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, float4 rand1, float2 rand2) {
    float3 directLighting = float3(0.0, 0.0, 0.0);

    // sample light
    {
        LightSample lightSample = light.sample(positionWs, rand1);
        float3 lightDirFs = frame.worldToFrame(lightSample.dirWs.xyz);

        if (dot(normalDirWs, lightSample.dirWs.xyz) > 0.0 && lightSample.pdf > 0.0) {
            RayDesc ray;
            ray.Origin = positionWs;
            ray.Direction = lightSample.dirWs.xyz;
            ray.TMin = 0.001;
            ray.TMax = lightSample.dirWs.w;

            if (!ShadowIntersection::hit(ray)) {
                float scatteringPdf = material.pdf(lightDirFs, outgoingDirFs);
                float3 brdf = material.eval(lightDirFs, outgoingDirFs);
                float weight = powerHeuristic(1, lightSample.pdf, 1, scatteringPdf);
                directLighting += lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
            }
        }
    }

    // sample material
    {
        MaterialSample materialSample = material.sample(outgoingDirFs, rand2);
        float3 brdfDirWs = frame.frameToWorld(materialSample.dirFs);

        if (dot(normalDirWs, brdfDirWs) > 0.0 && materialSample.pdf > 0.0) {
            RayDesc ray;
            ray.Origin = positionWs;
            ray.Direction = brdfDirWs;
            ray.TMin = 0.001;
            ray.TMax = 10000.0;

            if (!ShadowIntersection::hit(ray)) {
                float lightPdf = light.pdf(positionWs, brdfDirWs);
                float weight = powerHeuristic(1, materialSample.pdf, 1, lightPdf);
                float3 li = light.eval(positionWs, brdfDirWs);
                float3 brdf = material.eval(materialSample.dirFs, outgoingDirFs);
                directLighting += li * brdf * abs(Frame::cosTheta(materialSample.dirFs)) * weight / materialSample.pdf;
            }
        }
    }

    return directLighting;
}

// no MIS, just light
template <class Light, class Material>
float3 estimateDirect(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, float4 rand) {
    LightSample lightSample = light.sample(positionWs, rand);
    float3 lightDirFs = frame.worldToFrame(lightSample.dirWs.xyz);

    if (dot(normalDirWs, lightSample.dirWs.xyz) > 0.0 && lightSample.pdf > 0.0) {
        RayDesc ray;
        ray.Origin = positionWs;
        ray.Direction = lightSample.dirWs.xyz;
        ray.TMin = 0.001;
        ray.TMax = lightSample.dirWs.w - 0.001;

        if (!ShadowIntersection::hit(ray)) {
            float3 brdf = material.eval(lightDirFs, outgoingDirFs);
            return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) / lightSample.pdf;
        }
    }

    return float3(0, 0, 0);
}
