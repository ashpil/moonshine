#include "moonshine.h"

#include "mesh.hpp"
#include "renderDelegate.hpp"
#include "instancer.hpp"

#include <pxr/imaging/hd/meshUtil.h>
#include <pxr/imaging/hd/instancer.h>
#include <pxr/base/gf/matrix4f.h>

#include <iostream>

HdMoonshineMesh::HdMoonshineMesh(PXR_NS::SdfPath const& id) : PXR_NS::HdMesh(id) {}

PXR_NS::HdDirtyBits HdMoonshineMesh::GetInitialDirtyBitsMask() const {
    return PXR_NS::HdChangeTracker::DirtyPoints
        | PXR_NS::HdChangeTracker::DirtyTransform
        | PXR_NS::HdChangeTracker::DirtyInstancer;
}

PXR_NS::HdDirtyBits HdMoonshineMesh::_PropagateDirtyBits(PXR_NS::HdDirtyBits bits) const {
    return bits;
}

void HdMoonshineMesh::_InitRepr(PXR_NS::TfToken const& reprToken, PXR_NS::HdDirtyBits* dirtyBits) {}

void HdMoonshineMesh::Sync(PXR_NS::HdSceneDelegate* sceneDelegate, PXR_NS::HdRenderParam* renderParam, PXR_NS::HdDirtyBits* dirtyBits, PXR_NS::TfToken const& reprToken) {
    if (initialized_) {
        std::cerr << "* (multithreaded) Mesh id=" << GetId() << " already initialized!" << std::endl;
        return;
    }

    PXR_NS::SdfPath const& id = GetId();

    if (PXR_NS::HdChangeTracker::IsPrimvarDirty(*dirtyBits, id, PXR_NS::HdTokens->points)) {
        PXR_NS::HdRenderIndex& renderIndex = sceneDelegate->GetRenderIndex();
        HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex.GetRenderDelegate());

        const PXR_NS::HdMeshTopology& topology = GetMeshTopology(sceneDelegate);
        PXR_NS::HdMeshUtil meshUtil(&topology,id);
        PXR_NS::VtIntArray primitiveParams;
        PXR_NS::VtVec3iArray indices;
        meshUtil.ComputeTriangleIndices(&indices, &primitiveParams);

        const auto points = sceneDelegate->Get(id, PXR_NS::HdTokens->points).Get<PXR_NS::VtVec3fArray>();

        const MeshHandle mesh = HdMoonshineCreateMesh(renderDelegate->_moonshine, reinterpret_cast<const F32x3*>(points.cdata()), nullptr, nullptr, points.size(), reinterpret_cast<const U32x3*>(indices.cdata()), indices.size());

        const ImageHandle emissive = HdMoonshineCreateSolidTexture3(renderDelegate->_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 0.0f }, "emissive");
        const ImageHandle normal = HdMoonshineCreateSolidTexture2(renderDelegate->_moonshine, F32x2 { .x = 0.5f, .y = 0.5f }, "normal");
        const ImageHandle color = HdMoonshineCreateSolidTexture3(renderDelegate->_moonshine, F32x3 { .x = 0.5f, .y = 0.5f, .z = 0.5f }, "color");
        const MaterialHandle material = HdMoonshineCreateMaterialLambert(renderDelegate->_moonshine, normal, emissive, color);

        PXR_NS::GfMatrix4f transform(1.0f);

        if (PXR_NS::HdChangeTracker::IsTransformDirty(*dirtyBits, id)) {
            transform = PXR_NS::GfMatrix4f(sceneDelegate->GetTransform(id));
        }

        const Geometry geometry = Geometry {
            .mesh = mesh,
            .material = material,
            .sampled = false,
        };

        _UpdateInstancer(sceneDelegate, dirtyBits);
        const auto instancerId = GetInstancerId();
        PXR_NS::HdInstancer::_SyncInstancerAndParents(renderIndex, instancerId);

        if (PXR_NS::HdChangeTracker::IsInstancerDirty(*dirtyBits, id)) {
            if (instancerId.IsEmpty()) {
                const Mat3x4 matrix = Mat3x4 {
                    .x = F32x4 { .x = transform[0][0], .y = transform[1][0], .z = transform[2][0], .w = transform[3][0] },
                    .y = F32x4 { .x = transform[0][1], .y = transform[1][1], .z = transform[2][1], .w = transform[3][1] },
                    .z = F32x4 { .x = transform[0][2], .y = transform[1][2], .z = transform[2][2], .w = transform[3][2] },
                };
                HdMoonshineCreateInstance(renderDelegate->_moonshine, matrix, &geometry, 1);
            } else {
                PXR_NS::HdInstancer *instancer = renderIndex.GetInstancer(instancerId);
                PXR_NS::VtMatrix4dArray transforms = static_cast<HdMoonshineInstancer*>(instancer)->ComputeInstanceTransforms(id);

                for (size_t i = 0; i < transforms.size(); ++i) {
                    PXR_NS::GfMatrix4f instanceTransform = transform * PXR_NS::GfMatrix4f(transforms[i]);
                    const Mat3x4 matrix = Mat3x4 {
                        .x = F32x4 { .x = instanceTransform[0][0], .y = instanceTransform[1][0], .z = instanceTransform[2][0], .w = instanceTransform[3][0] },
                        .y = F32x4 { .x = instanceTransform[0][1], .y = instanceTransform[1][1], .z = instanceTransform[2][1], .w = instanceTransform[3][1] },
                        .z = F32x4 { .x = instanceTransform[0][2], .y = instanceTransform[1][2], .z = instanceTransform[2][2], .w = instanceTransform[3][2] },
                    };
                    HdMoonshineCreateInstance(renderDelegate->_moonshine, matrix, &geometry, 1);
                }
            }
        }
    }

    initialized_ = true;
    *dirtyBits = PXR_NS::HdChangeTracker::Clean;
}

