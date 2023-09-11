#include "mesh.hpp"

#include <iostream>

HdMoonshineMesh::HdMoonshineMesh(PXR_NS::SdfPath const& id) : PXR_NS::HdMesh(id) {
    std::cout << "Mesh constructor id=" << GetId() << std::endl;
}

PXR_NS::HdDirtyBits HdMoonshineMesh::GetInitialDirtyBitsMask() const {
    std::cout << "* (multithreaded) Get Initial Dirty Bits Mask id==" << GetId() << std::endl;
    return PXR_NS::HdChangeTracker::Clean
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
}

