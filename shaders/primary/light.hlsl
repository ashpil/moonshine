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
    LightSample sample(float3 positionWs, float3 triangleNormalDirWs, float2 square);

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

    float sample2D(float2 uv, out uint2 result) {
        uint2 size;
        dBackgroundTexture.GetDimensions(size.x, size.y);

        float pdf_y = sampleAlias<float, AliasEntry<float> >(dBackgroundMarginalAlias, size.y, 0, uv.y, result.y);
        float pdf_x = sampleAlias<float, AliasEntry<float> >(dBackgroundConditionalAlias, size.x, result.y * size.x, uv.x, result.x);

        return pdf_x * pdf_y * float(size.y) * float(size.x);
    }

    LightSample sample(float3 positionWs, float3 normalWs, float2 rand) {
        uint2 size;
        dBackgroundTexture.GetDimensions(size.x, size.y);

        uint2 discreteuv;
        float pdf2d = sample2D(rand, discreteuv);
        float2 uv = (float2(discreteuv) + float2(0.5, 0.5)) / size;

        float phi = uv.x * 2.0 * PI;
        float theta = uv.y * PI;

        float sinTheta = sin(theta);
        
        LightSample lightSample;
        lightSample.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sinTheta) : 0.0;
        lightSample.radiance = dBackgroundTexture.Load(float3(discreteuv, 0));
        lightSample.dirWs = sphericalToCartesian(sinTheta, cos(theta), phi);

        if (lightSample.pdf > 0.0 && ShadowIntersection::hit(offsetAlongNormal(positionWs, faceForward(normalWs, lightSample.dirWs)), lightSample.dirWs, INFINITY)) {
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
        dBackgroundTexture.GetDimensions(size.x, size.y);
        uint2 coords = clamp(uint2(uv * size), uint2(0, 0), size);
        float pdf2d = dBackgroundMarginalAlias[coords.y].data * dBackgroundConditionalAlias[coords.y * size.x + coords.x].data * size.x * size.y;
        float sinTheta = sin(phiTheta.y);
        l.pdf = sinTheta != 0.0 ? pdf2d / (2.0 * PI * PI * sin(phiTheta.y)) : 0.0;

        if (l.pdf > 0.0 && ShadowIntersection::hit(offsetAlongNormal(positionWs, faceForward(normalWs, dirWs)), dirWs, INFINITY)) {
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

// all mesh lights in scene
struct MeshLights : Light {
    static MeshLights create() {
        MeshLights map;
        return map;
    }

    LightSample sample(float3 positionWs, float3 triangleNormalDirWs, float2 rand) {
        LightSample lightSample;
        lightSample.pdf = 0.0;

        uint entryCount = dEmitterAliasTable[0].alias;
        float sum = dEmitterAliasTable[0].select;
        if (entryCount == 0 || sum == 0) return lightSample;

        uint idx;
        LightAliasData data = sampleAlias<LightAliasData, AliasEntry<LightAliasData> >(dEmitterAliasTable, entryCount, 1, rand.x, idx);
        uint instanceID = dInstances[data.instanceIndex].instanceID();

        float2 barycentrics = squareToTriangle(rand);
        MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(data.instanceIndex, data.geometryIndex, data.primitiveIndex, barycentrics).inWorld(data.instanceIndex);

        float3 emissive = dMaterialTextures[NonUniformResourceIndex(5 * materialIdx(instanceID, data.geometryIndex) + 3)].SampleLevel(dTextureSampler, attrs.texcoord, 0).rgb;

        float3 samplePositionToEmitterPositionWs = attrs.position - positionWs;
        float r2 = dot(samplePositionToEmitterPositionWs, samplePositionToEmitterPositionWs);
        float r = sqrt(r2);
        lightSample.radiance = emissive;
        lightSample.dirWs = samplePositionToEmitterPositionWs / r;
        lightSample.pdf = r2 / (abs(dot(-lightSample.dirWs, attrs.normal)) * sum);

        // compute precise ray endpoints
        float3 offsetLightPositionWs = offsetAlongNormal(attrs.position, attrs.triangleNormal);
        float3 offsetShadingPositionWs = offsetAlongNormal(positionWs, faceForward(triangleNormalDirWs, lightSample.dirWs));
        float tmax = distance(offsetLightPositionWs, offsetShadingPositionWs);

        if (lightSample.pdf > 0.0 && ShadowIntersection::hit(offsetShadingPositionWs, normalize(offsetLightPositionWs - offsetShadingPositionWs), tmax)) {
            lightSample.pdf = 0.0;
        }
        return lightSample;
    }

    LightEval eval(float3 positionWs, float3 triangleNormalDirWs, float3 dirWs) {
        LightEval l;
        // trace ray to determine if we hit an emissive mesh
        RayDesc ray;
        ray.Origin = offsetAlongNormal(positionWs, faceForward(triangleNormalDirWs, dirWs));
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
            float sum = dEmitterAliasTable[0].select;
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
// samples light and material
template <class Light, class Material>
float3 estimateDirectMISLightMaterial(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 triangleNormalDirWs, float4 rand) {
    float3 directLighting = float3(0.0, 0.0, 0.0);

    // sample light
    {
        LightSample lightSample = light.sample(positionWs, triangleNormalDirWs, rand.xy);

        if (lightSample.pdf > 0.0) {
            float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);
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
        MaterialSample materialSample = material.sample(outgoingDirFs, rand.zw);

        if (materialSample.pdf > 0.0) {
            float3 brdfDirWs = frame.frameToWorld(materialSample.dirFs);
            LightEval lightContrib = light.eval(positionWs, triangleNormalDirWs, brdfDirWs);
            if (lightContrib.pdf > 0.0) {
                float3 brdf = material.eval(materialSample.dirFs, outgoingDirFs);
                float weight = powerHeuristic(1, materialSample.pdf, 1, lightContrib.pdf);
                directLighting += lightContrib.radiance * brdf * abs(Frame::cosTheta(materialSample.dirFs)) * weight / materialSample.pdf;
            }
        }
    }

    return directLighting;
}

// estimates direct lighting from light + brdf via MIS
// only samples light
template <class Light, class Material>
float3 estimateDirectMISLight(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 triangleNormalDirWs, float2 rand, uint samplesTaken) {
    LightSample lightSample = light.sample(positionWs, triangleNormalDirWs, rand);

    if (lightSample.pdf > 0.0) {
        float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);
        float scatteringPdf = material.pdf(lightDirFs, outgoingDirFs);
        if (scatteringPdf > 0.0) {
            float3 brdf = material.eval(lightDirFs, outgoingDirFs);
            float weight = powerHeuristic(samplesTaken, lightSample.pdf, 1, scatteringPdf);
            return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) * weight / lightSample.pdf;
        }
    }

    return 0.0;
}

// no MIS, just light
template <class Light, class Material>
float3 estimateDirect(Frame frame, Light light, Material material, float3 outgoingDirFs, float3 positionWs, float3 normalDirWs, float2 rand) {
    LightSample lightSample = light.sample(positionWs, normalDirWs, rand);
    float3 lightDirFs = frame.worldToFrame(lightSample.dirWs);

    if (lightSample.pdf > 0.0) {
        float3 brdf = material.eval(lightDirFs, outgoingDirFs);
        return lightSample.radiance * brdf * abs(Frame::cosTheta(lightDirFs)) / lightSample.pdf;
    } else {
        return float3(0, 0, 0);
    }
}
