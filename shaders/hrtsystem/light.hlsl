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

float areaMeasureToSolidAngleMeasure(float3 pos1, float3 pos2, float3 dir1, float3 dir2) {
    float r2 = dot(pos1 - pos2, pos1 - pos2);
    float lightCos = dot(-dir1, dir2);

    return lightCos > 0.0f ? r2 / lightCos : 0.0f;
}

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

        lightSample.radiance = getEmissive(materialIdx(instanceID, data.geometryIndex), attrs.texcoord);
        lightSample.dirWs = normalize(attrs.position - positionWs);
        lightSample.pdf = areaMeasureToSolidAngleMeasure(attrs.position, positionWs, lightSample.dirWs, attrs.triangleFrame.n) / sum;

        // compute precise ray endpoints
        float3 offsetLightPositionWs = offsetAlongNormal(attrs.position, attrs.triangleFrame.n);
        float3 offsetShadingPositionWs = offsetAlongNormal(positionWs, faceForward(triangleNormalDirWs, lightSample.dirWs));
        float tmax = distance(offsetLightPositionWs, offsetShadingPositionWs);

        if (lightSample.pdf > 0.0 && ShadowIntersection::hit(offsetShadingPositionWs, normalize(offsetLightPositionWs - offsetShadingPositionWs), tmax)) {
            lightSample.pdf = 0.0;
        }
        return lightSample;
    }

    LightEval eval(float3 positionWs, float3 triangleNormalDirWs, float3 dirWs) {
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

        LightEval l;
        if (geometry.sampled) {
            MeshAttributes attrs = MeshAttributes::lookupAndInterpolate(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics).inWorld(its.instanceIndex);
            float sum = dEmitterAliasTable[0].select;
            l.pdf = areaMeasureToSolidAngleMeasure(attrs.position, positionWs, dirWs, attrs.triangleFrame.n) / sum;
            l.radiance = getEmissive(materialIdx(instanceID, its.geometryIndex), attrs.texcoord);
        } else {
            // geometry not sampled, pdf is zero
            l.pdf = 0.0;
        }

        return l;
    }
};
