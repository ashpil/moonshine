struct LightSample {
    float3 dirWs;
    float3 radiance;
    float pdf;
};

struct LightEval {
    float3 radiance;
    float pdf;
};

interface Light {
    // samples a light direction based on given position and geometric normal, returning
    // radiance at that point from light and pdf of this direction + radiance
    //
    // pdf is with respect to unobstructed solid angle
    // should trace a ray to determine obstruction
    LightSample sample(float3 positionWs, float3 normalWs, inout Rng rng);

    // evaluates a given position, returning radiance arriving at that point from
    // light and the pdf of that radiance
    //
    // pdf is with respect to unobstructed solid angle
    // should trace a ray to determine obstruction
    LightEval eval(float3 positionWs, float3 normalWs, float3 dirWs);
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

    LightSample sample(float3 positionWs, float3 normalWs, inout Rng rng) {
        float2 uv;
        float pdf2d = sample2D(float2(rng.getFloat(), rng.getFloat()), uv);

        float phi = uv.x * 2.0 * PI;
        float theta = uv.y * PI;

        float sinTheta = sin(theta);
        
        LightSample lightSample;
        lightSample.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sinTheta) : 0.0;
        lightSample.radiance = dBackgroundTexture.SampleLevel(dBackgroundSampler, uv, 0);
        lightSample.dirWs = sphericalToCartesian(sinTheta, cos(theta), phi);

        if (lightSample.pdf > 0.0 && ShadowIntersection::hit(offsetAlongNormal(positionWs, normalWs), lightSample.dirWs, INFINITY)) {
            lightSample.pdf = 0.0;
        }

        return lightSample;
    }

    LightEval eval(float3 positionWs, float3 normalWs, float3 dirWs) {
        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);

        // compute radiance
        LightEval l;
        l.radiance = dBackgroundTexture.SampleLevel(dBackgroundSampler, uv, 0);

        // compute pdf
        uint2 size;
        dConditionalCdfs.GetDimensions(size.x, size.y);
        int width = size.x - 1;
        int height = size.y;

        uint2 coords = clamp(uint2(uv * float2(width, height)), uint2(0, 0), uint2(width - 1, height - 1));
        float pdf2d = dConditionalPdfsIntegrals[coords] / dMarginalPdfIntegral[height];
        float sinTheta = sin(phiTheta.y);
        l.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sin(phiTheta.y)) : 0.0;

        if (l.pdf > 0.0 && ShadowIntersection::hit(offsetAlongNormal(positionWs, normalWs), dirWs, INFINITY)) {
            l.pdf = 0.0;
        }
        return l;
    }

    float3 incomingRadiance(float3 dirWs) {
        float2 phiTheta = cartesianToSpherical(dirWs);
        float2 uv = phiTheta / float2(2 * PI, PI);
        return dBackgroundTexture.SampleLevel(dBackgroundSampler, uv, 0);
    }
};

struct CandidateData {
    float3 position;
    float3 normal;
    float3 dir;
    float3 radiance;
    float pdf;
};

// all mesh lights in scene
struct MeshLights : Light {
    static MeshLights create() {
        MeshLights map;
        return map;
    }

    LightSample sample(float3 positionWs, float3 normalWs, inout Rng rng) {
        LightSample lightSample;
        uint emitterCount = dEmitterAliasTable[0].alias;
        float sum = dEmitterAliasTable[0].weight;
        if (emitterCount != 0) {
            const uint M = 2;
            Reservoir<CandidateData> res = Reservoir<CandidateData>::init(rng.getFloat());
            float coinp = rng.getFloat();
            for (uint i = 0; i < M; i++) {
                // find relevant entry
                uint x = rng.getFloat() * emitterCount;
                AliasEntry entry = dEmitterAliasTable[x + 1];
                if (!coinFlipRemap(entry.weight, coinp)) {
                    entry = dEmitterAliasTable[entry.alias + 1];
                }

                // compute information about it
                uint instanceID = dInstances[entry.instanceIndex].instanceID();

                float2 barycentrics = squareToTriangle(float2(rng.getFloat(), rng.getFloat()));
                MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(entry.instanceIndex, entry.geometryIndex, entry.primitiveIndex, barycentrics).inWorld(entry.instanceIndex);

                float3 emissive = dMaterialTextures[NonUniformResourceIndex(5 * materialIdx(instanceID, entry.geometryIndex) + 3)].SampleLevel(dTextureSampler, attrs.texcoord, 0).rgb;

                float3 samplePositionToEmitterPositionWs = attrs.position - positionWs;
                float r2 = dot(samplePositionToEmitterPositionWs, samplePositionToEmitterPositionWs);
                float r = sqrt(r2);

                CandidateData c;
                c.position = attrs.position;
                c.normal = attrs.normal;
                c.dir = samplePositionToEmitterPositionWs / r;
                c.radiance = emissive;
                c.pdf = saturate(dot(-c.dir, attrs.normal)) / r2;

                res.update(c, c.pdf * sum);
            }
            if (res.weightSum == 0.0) {
                lightSample.pdf = 0.0;
            } else {
                lightSample.pdf = res.weightSum / (res.numSamplesSeen * res.selected.pdf);
                lightSample.pdf = 1 / lightSample.pdf;
                lightSample.radiance = res.selected.radiance * res.selected.pdf;
                lightSample.dirWs = res.selected.dir;

                // compute precise ray endpoints
                float3 offsetLightPositionWs = offsetAlongNormal(res.selected.position, res.selected.normal);
                float3 offsetShadingPositionWs = offsetAlongNormal(positionWs, normalWs);
                float tmax = distance(offsetLightPositionWs, offsetShadingPositionWs);

                if (lightSample.pdf > 0.0 && ShadowIntersection::hit(offsetShadingPositionWs, normalize(offsetLightPositionWs - offsetShadingPositionWs), tmax)) {
                    lightSample.pdf = 0.0;
                }
            }
        } else {
            lightSample.pdf = 0.0;
        }
        return lightSample;
    }

    LightEval eval(float3 positionWs, float3 normalWs, float3 dirWs) {
        LightEval l;
        // trace ray to determine if we hit an emissive mesh
        RayDesc ray;
        ray.Origin = offsetAlongNormal(positionWs, normalWs);
        ray.Direction = dirWs;
        ray.TMin = 0.0;
        ray.TMax = INFINITY;
        Intersection its = Intersection::find(ray);

        // process intersection
        uint instanceID = dInstances[its.instanceIndex].instanceID();
        Geometry geometry = getGeometry(instanceID, its.geometryIndex);

        if (geometry.sampled) {
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.attribs).inWorld(its.instanceIndex);

            float3 samplePositionToEmitterPositionWs = attrs.position - positionWs;
            float r2 = dot(samplePositionToEmitterPositionWs, samplePositionToEmitterPositionWs);
            float sum = dEmitterAliasTable[0].weight;
            l.pdf = r2 / (abs(dot(-dirWs, attrs.normal)) * sum);
            l.radiance = dMaterialTextures[NonUniformResourceIndex(5 * materialIdx(instanceID, its.geometryIndex) + 3)].SampleLevel(dTextureSampler, attrs.texcoord, 0).rgb;
        } else {
            // geometry not sampled, pdf is zero
            l.pdf = 0.0;
        }

        return l;
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
float3 estimateDirectMIS(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, inout Rng rng) {
    float3 directLighting = float3(0.0, 0.0, 0.0);

    // sample light
    {
        LightSample lightSample = light.sample(positionWs, normalDirWs, rng);
        float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);

        if (lightSample.pdf > 0.0) {
            float scatteringPdf = material.pdf(lightDirFs, outgoingDirFs);
            if (scatteringPdf > 0.0) {
                float3 brdf = material.eval(lightDirFs, outgoingDirFs);
                float weight = powerHeuristic(1, lightSample.pdf, 1, scatteringPdf);
                directLighting += lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
            }
        }
    }

    // sample material
    {
        MaterialSample materialSample = material.sample(outgoingDirFs, float2(rng.getFloat(), rng.getFloat()));
        float3 brdfDirWs = frame.frameToWorld(materialSample.dirFs);

        if (materialSample.pdf > 0.0) {
            LightEval lightContrib = light.eval(positionWs, normalDirWs, brdfDirWs);
            if (lightContrib.pdf > 0.0) {
                float3 brdf = material.eval(materialSample.dirFs, outgoingDirFs);
                float weight = powerHeuristic(1, materialSample.pdf, 1, lightContrib.pdf);
                directLighting += lightContrib.radiance * brdf * abs(Frame::cosTheta(materialSample.dirFs)) * weight / materialSample.pdf;
            }
        }
    }

    return directLighting;
}

// no MIS, just light
template <class Light, class Material>
float3 estimateDirect(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, inout Rng rng) {
    LightSample lightSample = light.sample(positionWs, normalDirWs, rng);
    float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);

    if (lightSample.pdf > 0.0) {
        float3 brdf = material.eval(lightDirFs, outgoingDirFs);
        return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) / lightSample.pdf;
    } else {
        return float3(0, 0, 0);
    }
}
