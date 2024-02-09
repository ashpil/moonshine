#include "moonshine.h"

#include "mesh.hpp"
#include "renderDelegate.hpp"
#include "instancer.hpp"

#include <pxr/imaging/hd/meshUtil.h>
#include <pxr/imaging/hd/instancer.h>
#include <pxr/base/gf/matrix4f.h>

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineMesh::HdMoonshineMesh(SdfPath const& id) : HdMesh(id) {}

HdDirtyBits HdMoonshineMesh::GetInitialDirtyBitsMask() const {
    return HdChangeTracker::DirtyPoints
        | HdChangeTracker::DirtyTransform
        | HdChangeTracker::DirtyInstancer;
}

HdDirtyBits HdMoonshineMesh::_PropagateDirtyBits(HdDirtyBits bits) const {
    return bits;
}

void HdMoonshineMesh::_InitRepr(TfToken const& reprToken, HdDirtyBits* dirtyBits) {}

void HdMoonshineMesh::Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* hdRenderParam, HdDirtyBits* dirtyBits, TfToken const& reprToken) {
    SdfPath const& id = GetId();

    HdRenderIndex& renderIndex = sceneDelegate->GetRenderIndex();
    HdMoonshineRenderParam* renderParam = static_cast<HdMoonshineRenderParam*>(hdRenderParam);
    HdMoonshine* msne = renderParam->_moonshine;

    bool transform_changed = HdChangeTracker::IsTransformDirty(*dirtyBits, id) || HdChangeTracker::IsInstancerDirty(*dirtyBits, id);

    if (HdChangeTracker::IsTransformDirty(*dirtyBits, id)) {
        _transform = GfMatrix4f(sceneDelegate->GetTransform(id));
        *dirtyBits = *dirtyBits & ~HdChangeTracker::DirtyTransform;
    }

    const auto instancerId = GetInstancerId();
    _UpdateInstancer(sceneDelegate, dirtyBits);
    HdInstancer::_SyncInstancerAndParents(renderIndex, instancerId);

    bool instancer_count_changed = false;

    if (HdChangeTracker::IsInstancerDirty(*dirtyBits, id)) {
        const size_t old_len = _instancesTransforms.size();
        _instancesTransforms.clear();
        if (instancerId.IsEmpty()) {
            _instancesTransforms.push_back(GfMatrix4f(1.0));
        } else {
            HdInstancer *instancer = renderIndex.GetInstancer(instancerId);
            VtMatrix4dArray instanceTransforms = static_cast<HdMoonshineInstancer*>(instancer)->ComputeInstanceTransforms(id);
            for (size_t i = 0; i < instanceTransforms.size(); i++) {
                _instancesTransforms.push_back(GfMatrix4f(instanceTransforms[i]));
            }
        }
        const size_t new_len = _instancesTransforms.size();
        bool instancer_count_changed = old_len != new_len;
        *dirtyBits = *dirtyBits & ~HdChangeTracker::DirtyInstancer;
    }

    bool mesh_changed = HdChangeTracker::IsPrimvarDirty(*dirtyBits, id, HdTokens->points);

    if (HdChangeTracker::IsPrimvarDirty(*dirtyBits, id, HdTokens->points)) {
        const HdMeshTopology& topology = GetMeshTopology(sceneDelegate);
        HdMeshUtil meshUtil(&topology,id);
        VtIntArray primitiveParams;
        VtVec3iArray indices;
        meshUtil.ComputeTriangleIndices(&indices, &primitiveParams);

        const auto points = sceneDelegate->Get(id, HdTokens->points).Get<VtVec3fArray>();

        // TODO: destroy mesh
        _mesh = HdMoonshineCreateMesh(msne, reinterpret_cast<const F32x3*>(points.cdata()), nullptr, nullptr, points.size(), reinterpret_cast<const U32x3*>(indices.cdata()), indices.size());

        *dirtyBits = *dirtyBits & ~HdChangeTracker::DirtyPoints;
    }

    const Geometry geometry = Geometry {
        .mesh = _mesh,
        .material = renderParam->_material,
        .sampled = false,
    };

    if (mesh_changed || instancer_count_changed) {
        // need to delete all
        for (const InstanceHandle instance : _instances) {
            HdMoonshineDestroyInstance(static_cast<HdMoonshineRenderParam*>(renderParam)->_moonshine, instance);
        }
        _instances.clear();

        for (size_t i = 0; i < _instancesTransforms.size(); i++) {
            GfMatrix4f instanceTransform = _transform * _instancesTransforms[i];
            const Mat3x4 matrix = Mat3x4 {
                .x = F32x4 { .x = instanceTransform[0][0], .y = instanceTransform[1][0], .z = instanceTransform[2][0], .w = instanceTransform[3][0] },
                .y = F32x4 { .x = instanceTransform[0][1], .y = instanceTransform[1][1], .z = instanceTransform[2][1], .w = instanceTransform[3][1] },
                .z = F32x4 { .x = instanceTransform[0][2], .y = instanceTransform[1][2], .z = instanceTransform[2][2], .w = instanceTransform[3][2] },
            };
            _instances.push_back(HdMoonshineCreateInstance(msne, matrix, &geometry, 1));
        }
    } else if (transform_changed) {
        for (size_t i = 0; i < _instancesTransforms.size(); i++) {
            GfMatrix4f instanceTransform = _transform * _instancesTransforms[i];
            const Mat3x4 matrix = Mat3x4 {
                .x = F32x4 { .x = instanceTransform[0][0], .y = instanceTransform[1][0], .z = instanceTransform[2][0], .w = instanceTransform[3][0] },
                .y = F32x4 { .x = instanceTransform[0][1], .y = instanceTransform[1][1], .z = instanceTransform[2][1], .w = instanceTransform[3][1] },
                .z = F32x4 { .x = instanceTransform[0][2], .y = instanceTransform[1][2], .z = instanceTransform[2][2], .w = instanceTransform[3][2] },
            };
            HdMoonshineSetInstanceTransform(msne, _instances[i], matrix);
        }
    }

    if (!HdChangeTracker::IsClean(*dirtyBits)) {
        TF_CODING_ERROR("Dirty bits %s of %s were ignored!", HdChangeTracker::StringifyDirtyBits(*dirtyBits).c_str(), GetId().GetText());
    }
}

void HdMoonshineMesh::Finalize(HdRenderParam *renderParam) {
    for (const InstanceHandle instance : _instances) {
        HdMoonshineDestroyInstance(static_cast<HdMoonshineRenderParam*>(renderParam)->_moonshine, instance);
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
