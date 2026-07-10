#pragma once

#include "moonshine.h"
#include "renderParam.hpp"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/light.h"
#include "pxr/base/gf/vec2f.h"
#include "pxr/base/gf/vec3f.h"

#include <optional>

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineDomeLight final : public HdLight {
public:
    HdMoonshineDomeLight(SdfPath const& id);
    ~HdMoonshineDomeLight() override = default;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override;

    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Finalize(HdRenderParam* renderParam) override;
protected:
    HdMoonshineDomeLight(const HdMoonshineDomeLight&) = delete;
    HdMoonshineDomeLight &operator =(const HdMoonshineDomeLight&) = delete;
};

// implemented as an emissive mesh instance
class HdMoonshineAreaLight : public HdLight {
public:
    HdMoonshineAreaLight(SdfPath const& id, HdMoonshineRenderParam& renderParam);
    ~HdMoonshineAreaLight() override = default;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override;

    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Finalize(HdRenderParam* renderParam) override;
protected:
    HdMoonshineAreaLight(const HdMoonshineAreaLight&) = delete;
    HdMoonshineAreaLight &operator =(const HdMoonshineAreaLight&) = delete;

    struct Shape {
        MeshHandle mesh;
        GfVec2f size; // local XY scale baked into the instance transform
        float area;   // local surface area, for normalize
    };
    virtual Shape ComputeShape(HdSceneDelegate* sceneDelegate, HdMoonshineRenderParam& renderParam) const = 0;
private:
    MaterialHandle _material;
    std::optional<InstanceHandle> _instance;
    GfVec3f _radiance = GfVec3f(0.0f); // matches the initial black emissive
};

// unit quad scaled by width/height
class HdMoonshineRectLight final : public HdMoonshineAreaLight {
public:
    using HdMoonshineAreaLight::HdMoonshineAreaLight;
protected:
    Shape ComputeShape(HdSceneDelegate* sceneDelegate, HdMoonshineRenderParam& renderParam) const override;
};

// unit-radius disk scaled by radius
class HdMoonshineDiskLight final : public HdMoonshineAreaLight {
public:
    using HdMoonshineAreaLight::HdMoonshineAreaLight;
protected:
    Shape ComputeShape(HdSceneDelegate* sceneDelegate, HdMoonshineRenderParam& renderParam) const override;
};

// does nothing. we have fake support for this because usdview will not offer its default
// dome light unless distant light support is claimed, and we want the default dome light
class HdMoonshineDistantLight final : public HdLight {
public:
    HdMoonshineDistantLight(SdfPath const& id) : HdLight(id) {}
    ~HdMoonshineDistantLight() override = default;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override {
        *dirtyBits = HdLight::Clean;
    }

    HdDirtyBits GetInitialDirtyBitsMask() const override {
        return HdLight::AllDirty;
    }
protected:
    HdMoonshineDistantLight(const HdMoonshineDistantLight&) = delete;
    HdMoonshineDistantLight &operator =(const HdMoonshineDistantLight&) = delete;
};

PXR_NAMESPACE_CLOSE_SCOPE
