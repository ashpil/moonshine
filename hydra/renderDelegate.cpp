#include <memory>

#include <pxr/imaging/hd/extComputation.h>

#include "renderDelegate.hpp"
#include "renderPass.hpp"
#include "renderBuffer.hpp"
#include "mesh.hpp"
#include "camera.hpp"
#include "instancer.hpp"
#include "material.hpp"

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
    (rebuildPipeline)
);

const TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_RPRIM_TYPES = {
    HdPrimTypeTokens->mesh,
};

const TfTokenVector HdMoonshineRenderDelegate::SUPPORTED_SPRIM_TYPES = {
    HdPrimTypeTokens->camera,
    HdPrimTypeTokens->extComputation,
    HdPrimTypeTokens->material,
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

HdCommandDescriptors HdMoonshineRenderDelegate::GetCommandDescriptors() const {
    HdCommandDescriptor commandDesc(_tokens->rebuildPipeline, "Rebuild pipeline", {});
    return { commandDesc };
}

bool HdMoonshineRenderDelegate::InvokeCommand(const TfToken &command, const HdCommandArgs &args) {
    if (command == _tokens->rebuildPipeline) {
        HdMoonshineRebuildPipeline(_moonshine);
        return true;
    } else {
        TF_CODING_ERROR("Unknown command %s!", command.GetText());
        return false;
    }
}

void HdMoonshineRenderDelegate::_Initialize() {
    _moonshine = HdMoonshineCreate();
    _resourceRegistry = std::make_shared<HdResourceRegistry>();
    _renderParam = std::make_unique<HdMoonshineRenderParam>(_moonshine);
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
        return new HdMoonshineMesh(rprimId, *_renderParam);
    } else {
        TF_CODING_ERROR("Unknown Rprim type %s", typeId.GetText());
        return nullptr;
    }
}

void HdMoonshineRenderDelegate::DestroyRprim(HdRprim *rPrim) {
    delete rPrim;
}

HdSprim* HdMoonshineRenderDelegate::CreateSprim(TfToken const& typeId, SdfPath const& sprimId) {
    if (typeId == HdPrimTypeTokens->camera) {
        return new HdMoonshineCamera(sprimId);
    } else if (typeId == HdPrimTypeTokens->extComputation) {
        return new HdExtComputation(sprimId);
    } else if (typeId == HdPrimTypeTokens->material) {
        return new HdMoonshineMaterial(sprimId, *_renderParam);
    } else {
        TF_CODING_ERROR("Unknown Sprim type %s", typeId.GetText());
        return nullptr;
    }
}

HdSprim* HdMoonshineRenderDelegate::CreateFallbackSprim(TfToken const& typeId) {
    if (typeId == HdPrimTypeTokens->camera) {
        return new HdMoonshineCamera(SdfPath::EmptyPath());
    } else if (typeId == HdPrimTypeTokens->extComputation) {
        return new HdExtComputation(SdfPath::EmptyPath());
    } else if (typeId == HdPrimTypeTokens->material) {
        return new HdMoonshineMaterial(SdfPath::EmptyPath(), *_renderParam);
    } else {
        TF_CODING_ERROR("Unknown fallback Sprim type %s", typeId.GetText());
        return nullptr;
    }
}

void HdMoonshineRenderDelegate::DestroySprim(HdSprim *sPrim) {
    delete sPrim;
}

HdBprim* HdMoonshineRenderDelegate::CreateBprim(TfToken const& typeId, SdfPath const& bprimId) {
    if (typeId == HdPrimTypeTokens->renderBuffer) {
        return new HdMoonshineRenderBuffer(bprimId, this);
    } else {
        TF_CODING_ERROR("Unknown Bprim type %s", typeId.GetText());
        return nullptr;
    }
}

HdBprim* HdMoonshineRenderDelegate::CreateFallbackBprim(TfToken const& typeId) {
    if (typeId == HdPrimTypeTokens->renderBuffer) {
        return new HdMoonshineRenderBuffer(SdfPath::EmptyPath(), this);
    } else {
        TF_CODING_ERROR("Unknown fallback Bprim type %s", typeId.GetText());
        return nullptr;
    }
}

void HdMoonshineRenderDelegate::DestroyBprim(HdBprim *bPrim) {
    delete bPrim;
}

HdInstancer* HdMoonshineRenderDelegate::CreateInstancer(HdSceneDelegate *delegate, SdfPath const& id) {
    return new HdMoonshineInstancer(delegate, id);
}

void HdMoonshineRenderDelegate::DestroyInstancer(HdInstancer *instancer) {
    delete instancer;
}

HdRenderParam* HdMoonshineRenderDelegate::GetRenderParam() const {
    return _renderParam.get();
}

HdAovDescriptor HdMoonshineRenderDelegate::GetDefaultAovDescriptor(TfToken const& name) const {
    if (name == HdAovTokens->color) {
        return HdAovDescriptor(HdFormatFloat32Vec3, false, VtValue(GfVec4f(0.0f)));
    } else {
        return HdAovDescriptor();
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
