#pragma once

#include "moonshine.h"
#include "renderParam.hpp"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/light.h"
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

// implemented as an emissive quad instance
class HdMoonshineRectLight final : public HdLight {
public:
    HdMoonshineRectLight(SdfPath const& id, HdMoonshineRenderParam& renderParam);
    ~HdMoonshineRectLight() override = default;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override;

    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Finalize(HdRenderParam* renderParam) override;
protected:
    HdMoonshineRectLight(const HdMoonshineRectLight&) = delete;
    HdMoonshineRectLight &operator =(const HdMoonshineRectLight&) = delete;
private:
    MaterialHandle _material;
    std::optional<InstanceHandle> _instance;
    GfVec3f _radiance = GfVec3f(0.0f); // matches the initial black emissive
};

PXR_NAMESPACE_CLOSE_SCOPE
