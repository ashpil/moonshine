#pragma once

#include <vector>

#include <pxr/pxr.h>
#include <pxr/imaging/hd/mesh.h>
#include <pxr/base/gf/matrix4f.h>

#include "renderParam.hpp"

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineMesh final : public HdMesh {
public:
    HdMoonshineMesh(SdfPath const& id, const HdMoonshineRenderParam& renderParam);
    ~HdMoonshineMesh() override = default;

    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits, TfToken const &reprToken) override;

    void Finalize(HdRenderParam *renderParam) override;
protected:
    void _InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits) override;

    HdDirtyBits _PropagateDirtyBits(HdDirtyBits bits) const override;

    HdMoonshineMesh(const HdMoonshineMesh&) = delete;
    HdMoonshineMesh &operator =(const HdMoonshineMesh&) = delete;
private:
    std::optional<HdInterpolation> FindPrimvarInterpolation(HdSceneDelegate* sceneDelegate, TfToken name) const;

    template<typename T>
    VtArray<T> ComputePrimvar(HdSceneDelegate* sceneDelegate, VtVec3iArray const& indices, TfToken primvarName) const;
    
    GfMatrix4f _transform{1.0f};
    MeshHandle _mesh;
    MaterialHandle _material;

    // these two have same len
    std::vector<InstanceHandle> _instances = {};
    std::vector<GfMatrix4f> _instancesTransforms = {};
};

PXR_NAMESPACE_CLOSE_SCOPE
