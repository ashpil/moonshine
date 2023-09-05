#include "renderDelegate.hpp"

#include <iostream>

const PXR_NS::TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_RPRIM_TYPES = {
    PXR_NS::HdPrimTypeTokens->mesh,
};

const PXR_NS::TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_SPRIM_TYPES = {
};

const PXR_NS::TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_BPRIM_TYPES = {
};

HdMoonshineRenderDelegate::HdMoonshineRenderDelegate() : HdRenderDelegate() {
    _Initialize();
}

HdMoonshineRenderDelegate::HdMoonshineRenderDelegate(PXR_NS::HdRenderSettingsMap const& settingsMap) : PXR_NS::HdRenderDelegate(settingsMap) {
    _Initialize();
}

void HdMoonshineRenderDelegate::_Initialize() {
    std::cout << "Creating Moonshine RenderDelegate" << std::endl;
    _resourceRegistry = std::make_shared<PXR_NS::HdResourceRegistry>();
}

HdMoonshineRenderDelegate::~HdMoonshineRenderDelegate() {
    _resourceRegistry.reset();
    std::cout << "Destroying Moonshine RenderDelegate" << std::endl;
}

PXR_NS::TfTokenVector const& HdMoonshineRenderDelegate::GetSupportedRprimTypes() const {
    return SUPPORTED_RPRIM_TYPES;
}

PXR_NS::TfTokenVector const& HdMoonshineRenderDelegate::GetSupportedSprimTypes() const {
    return SUPPORTED_SPRIM_TYPES;
}

PXR_NS::TfTokenVector const& HdMoonshineRenderDelegate::GetSupportedBprimTypes() const {
    return SUPPORTED_BPRIM_TYPES;
}

PXR_NS::HdResourceRegistrySharedPtr HdMoonshineRenderDelegate::GetResourceRegistry() const {
    return _resourceRegistry;
}

void HdMoonshineRenderDelegate::CommitResources(PXR_NS::HdChangeTracker *tracker) {
    std::cout << "=> CommitResources RenderDelegate" << std::endl;
}

PXR_NS::HdRenderPassSharedPtr HdMoonshineRenderDelegate::CreateRenderPass(PXR_NS::HdRenderIndex *index, PXR_NS::HdRprimCollection const& collection) {
    std::cout << "Create RenderPass with Collection=" << collection.GetName() << std::endl; 

    return PXR_NS::HdRenderPassSharedPtr(nullptr);
}

PXR_NS::HdRprim* HdMoonshineRenderDelegate::CreateRprim(PXR_NS::TfToken const& typeId, PXR_NS::SdfPath const& rprimId) {
    std::cout << "Create Moonshine Rprim type=" << typeId.GetText() << " id=" << rprimId << std::endl;

    if (typeId == PXR_NS::HdPrimTypeTokens->mesh) {
        return nullptr;
    } else {
    }
    return nullptr;
}

void HdMoonshineRenderDelegate::DestroyRprim(PXR_NS::HdRprim *rPrim) {
    std::cout << "Destroy Moonshine Rprim id=" << std::endl;
}

PXR_NS::HdSprim* HdMoonshineRenderDelegate::CreateSprim(PXR_NS::TfToken const& typeId, PXR_NS::SdfPath const& sprimId) {
    return nullptr;
}

PXR_NS::HdSprim* HdMoonshineRenderDelegate::CreateFallbackSprim(PXR_NS::TfToken const& typeId) {
    return nullptr;
}

void HdMoonshineRenderDelegate::DestroySprim(PXR_NS::HdSprim *sPrim) {
}

PXR_NS::HdBprim* HdMoonshineRenderDelegate::CreateBprim(PXR_NS::TfToken const& typeId, PXR_NS::SdfPath const& bprimId) {
    return nullptr;
}

PXR_NS::HdBprim* HdMoonshineRenderDelegate::CreateFallbackBprim(PXR_NS::TfToken const& typeId) {
    return nullptr;
}

void HdMoonshineRenderDelegate::DestroyBprim(PXR_NS::HdBprim *bPrim) {
}

PXR_NS::HdInstancer* HdMoonshineRenderDelegate::CreateInstancer(PXR_NS::HdSceneDelegate *delegate, PXR_NS::SdfPath const& id) {
    return nullptr;
}

void HdMoonshineRenderDelegate::DestroyInstancer(PXR_NS::HdInstancer *instancer) {
}

PXR_NS::HdRenderParam* HdMoonshineRenderDelegate::GetRenderParam() const {
    return nullptr;
}
