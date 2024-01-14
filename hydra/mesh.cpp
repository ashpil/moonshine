#include "moonshine.h"

#include "mesh.hpp"
#include "renderDelegate.hpp"

#include <pxr/imaging/hd/meshUtil.h>

#include <iostream>

HdMoonshineMesh::HdMoonshineMesh(PXR_NS::SdfPath const& id) : PXR_NS::HdMesh(id) {
    std::cout << "Mesh constructor id=" << GetId() << std::endl;
}

PXR_NS::HdDirtyBits HdMoonshineMesh::GetInitialDirtyBitsMask() const {
    std::cout << "* (multithreaded) Get Initial Dirty Bits Mask id==" << GetId() << std::endl;
    return PXR_NS::HdChangeTracker::DirtyPoints
        | PXR_NS::HdChangeTracker::DirtyTransform;
}

PXR_NS::HdDirtyBits HdMoonshineMesh::_PropagateDirtyBits(PXR_NS::HdDirtyBits bits) const {
    std::cout << "* (multithreaded) Propogate diry bits id=" << GetId() << bits << std::endl;
    return bits;
}

void HdMoonshineMesh::_InitRepr(PXR_NS::TfToken const& reprToken, PXR_NS::HdDirtyBits* dirtyBits) {
    std::cout << "* (multithreaded) _InitRepr id=" << GetId() << std::endl;
}

void HdMoonshineMesh::Sync(PXR_NS::HdSceneDelegate* sceneDelegate, PXR_NS::HdRenderParam* renderParam, PXR_NS::HdDirtyBits* dirtyBits, PXR_NS::TfToken const& reprToken) {
    std::cout << "* (multithreaded) Sync Moonshine Mesh id=" << GetId() << std::endl;
    if (*dirtyBits & PXR_NS::HdChangeTracker::DirtyPoints
        || *dirtyBits & PXR_NS::HdChangeTracker::DirtyTransform) {

        PXR_NS::HdRenderIndex& renderIndex = sceneDelegate->GetRenderIndex();
        HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex.GetRenderDelegate());

        const PXR_NS::HdMeshTopology& topology = GetMeshTopology(sceneDelegate);
        PXR_NS::HdMeshUtil meshUtil(&topology, GetId());
        PXR_NS::VtIntArray primitiveParams;
        PXR_NS::VtVec3iArray indices;
        meshUtil.ComputeTriangleIndices(&indices, &primitiveParams);

        const auto points = sceneDelegate->Get(GetId(), PXR_NS::HdTokens->points).Get<PXR_NS::VtVec3fArray>();

        const MeshHandle mesh = HdMoonshineCreateMesh(renderDelegate->_moonshine, reinterpret_cast<const F32x3*>(points.cdata()), nullptr, nullptr, points.size(), reinterpret_cast<const U32x3*>(indices.cdata()), indices.size());

        const ImageHandle emissive = HdMoonshineCreateSolidTexture3(renderDelegate->_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 0.0f }, "emissive");
        const ImageHandle normal = HdMoonshineCreateSolidTexture2(renderDelegate->_moonshine, F32x2 { .x = 0.5f, .y = 0.5f }, "normal");
        const ImageHandle color = HdMoonshineCreateSolidTexture3(renderDelegate->_moonshine, F32x3 { .x = 0.0f, .y = 0.0f, .z = 0.0f }, "color");
        const MaterialHandle material = HdMoonshineCreateMaterialLambert(renderDelegate->_moonshine, normal, emissive, color);

        const auto transform = sceneDelegate->GetTransform(GetId());

        const Mat3x4 matrix = Mat3x4 {
            .x = F32x4 { .x = static_cast<float>(transform[0][0]), .y = static_cast<float>(transform[0][1]), .z = static_cast<float>(transform[0][2]), .w = static_cast<float>(transform[0][3]) },
            .y = F32x4 { .x = static_cast<float>(transform[1][0]), .y = static_cast<float>(transform[1][1]), .z = static_cast<float>(transform[1][2]), .w = static_cast<float>(transform[1][3]) },
            .z = F32x4 { .x = static_cast<float>(transform[2][0]), .y = static_cast<float>(transform[2][1]), .z = static_cast<float>(transform[2][2]), .w = static_cast<float>(transform[2][3]) },
        };

        const Geometry geometry = Geometry {
            .material = material,
            .mesh = mesh,
            .sampled = false,
        };
        
        HdMoonshineCreateInstance(renderDelegate->_moonshine, matrix, &geometry, 1);
    }

    *dirtyBits = PXR_NS::HdChangeTracker::Clean;
}

