#include "renderDelegate.hpp"
#include "renderPass.hpp"
#include "renderBuffer.hpp"
#include "mesh.hpp"
#include "camera.hpp"
#include "instancer.hpp"

#include <iostream>

PXR_NAMESPACE_OPEN_SCOPE

const TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_RPRIM_TYPES = {
    HdPrimTypeTokens->mesh,
};

const TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_SPRIM_TYPES = {
    HdPrimTypeTokens->camera,
};

const TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_BPRIM_TYPES = {
    HdPrimTypeTokens->renderBuffer,
};

HdMoonshineRenderDelegate::HdMoonshineRenderDelegate() : HdRenderDelegate() {
    _Initialize();
}

HdMoonshineRenderDelegate::HdMoonshineRenderDelegate(HdRenderSettingsMap const& settingsMap) : HdRenderDelegate(settingsMap) {
    _Initialize();
}

void HdMoonshineRenderDelegate::_Initialize() {
    _moonshine = HdMoonshineCreate();
    _resourceRegistry = std::make_shared<HdResourceRegistry>();
}

HdMoonshineRenderDelegate::~HdMoonshineRenderDelegate() {
    _resourceRegistry.reset();
    HdMoonshineDestroy(_moonshine);
}

TfTokenVector const& HdMoonshineRenderDelegate::GetSupportedRprimTypes() const {
    return SUPPORTED_RPRIM_TYPES;
}

TfTokenVector const& HdMoonshineRenderDelegate::GetSupportedSprimTypes() const {
    return SUPPORTED_SPRIM_TYPES;
}

TfTokenVector const& HdMoonshineRenderDelegate::GetSupportedBprimTypes() const {
    return SUPPORTED_BPRIM_TYPES;
}

HdResourceRegistrySharedPtr HdMoonshineRenderDelegate::GetResourceRegistry() const {
    return _resourceRegistry;
}

void HdMoonshineRenderDelegate::CommitResources(HdChangeTracker *tracker) {}

HdRenderPassSharedPtr HdMoonshineRenderDelegate::CreateRenderPass(HdRenderIndex *index, HdRprimCollection const& collection) {
    return HdRenderPassSharedPtr(new HdMoonshineRenderPass(index, collection));
}

HdRprim* HdMoonshineRenderDelegate::CreateRprim(TfToken const& typeId, SdfPath const& rprimId) {
    if (typeId == HdPrimTypeTokens->mesh) {
        return new HdMoonshineMesh(rprimId);
    } else {
        std::cerr << "Unknown Rprim type=" << typeId.GetText() << " id=" << rprimId.GetText() << std::endl;
        return nullptr;
    }
}

void HdMoonshineRenderDelegate::DestroyRprim(HdRprim *rPrim) {}

HdSprim* HdMoonshineRenderDelegate::CreateSprim(TfToken const& typeId, SdfPath const& sprimId) {
    if (typeId == HdPrimTypeTokens->camera) {
        return new HdMoonshineCamera(sprimId);
    } else {
        std::cerr << "Unknown Sprim type=" << typeId.GetText() << " id=" << sprimId.GetText() << std::endl;
        return nullptr;
    }
}

HdSprim* HdMoonshineRenderDelegate::CreateFallbackSprim(TfToken const& typeId) {
    if (typeId == HdPrimTypeTokens->camera) {
        return new HdMoonshineCamera(SdfPath::EmptyPath());
    } else {
        std::cerr << "Unknown Sprim type=" << typeId.GetText() << std::endl;
        return nullptr;
    }
}

void HdMoonshineRenderDelegate::DestroySprim(HdSprim *sPrim) {}

HdBprim* HdMoonshineRenderDelegate::CreateBprim(TfToken const& typeId, SdfPath const& bprimId) {
    if (typeId == HdPrimTypeTokens->renderBuffer) {
        return new HdMoonshineRenderBuffer(bprimId, this);
    } else {
        std::cerr << "Unknown Bprim type=" << typeId.GetText() << std::endl;
        return nullptr;
    }
}

HdBprim* HdMoonshineRenderDelegate::CreateFallbackBprim(TfToken const& typeId) {
    if (typeId == HdPrimTypeTokens->renderBuffer) {
        return new HdMoonshineRenderBuffer(SdfPath::EmptyPath(), this);
    } else {
        std::cerr << "Unknown Bprim type=" << typeId.GetText() << std::endl;
        return nullptr;
    }
}

void HdMoonshineRenderDelegate::DestroyBprim(HdBprim *bPrim) {
}

HdInstancer* HdMoonshineRenderDelegate::CreateInstancer(HdSceneDelegate *delegate, SdfPath const& id) {
    return new HdMoonshineInstancer(delegate, id);
}

void HdMoonshineRenderDelegate::DestroyInstancer(HdInstancer *instancer) {
    delete instancer;
}

HdRenderParam* HdMoonshineRenderDelegate::GetRenderParam() const {
    return nullptr;
}

HdAovDescriptor HdMoonshineRenderDelegate::GetDefaultAovDescriptor(TfToken const& name) const {
    if (name == HdAovTokens->color) {
        return HdAovDescriptor(HdFormatFloat32Vec3, false, VtValue(GfVec4f(0.0f)));
    } else {
        return HdAovDescriptor();
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
