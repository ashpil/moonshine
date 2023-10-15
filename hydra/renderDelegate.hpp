#pragma once

#include "pxr/pxr.h"
#include "pxr/imaging/hd/renderDelegate.h"
#include "pxr/imaging/hd/resourceRegistry.h"
#include "pxr/base/tf/staticTokens.h"

#include "moonshine.h"

class HdMoonshineRenderDelegate final : public PXR_NS::HdRenderDelegate 
{
public:
    HdMoonshineRenderDelegate();
    HdMoonshineRenderDelegate(PXR_NS::HdRenderSettingsMap const& settingsMap);
    ~HdMoonshineRenderDelegate();

    const PXR_NS::TfTokenVector &GetSupportedRprimTypes() const override;
    const PXR_NS::TfTokenVector &GetSupportedSprimTypes() const override;
    const PXR_NS::TfTokenVector &GetSupportedBprimTypes() const override;

    PXR_NS::HdResourceRegistrySharedPtr GetResourceRegistry() const override;

    PXR_NS::HdRenderPassSharedPtr CreateRenderPass(PXR_NS::HdRenderIndex *index, PXR_NS::HdRprimCollection const& collection) override;

    PXR_NS::HdInstancer *CreateInstancer(PXR_NS::HdSceneDelegate *delegate, PXR_NS::SdfPath const& id) override;
    void DestroyInstancer(PXR_NS::HdInstancer *instancer) override;

    PXR_NS::HdRprim *CreateRprim(PXR_NS::TfToken const& typeId, PXR_NS::SdfPath const& rprimId) override;
    void DestroyRprim(PXR_NS::HdRprim *rPrim) override;

    PXR_NS::HdSprim *CreateSprim(PXR_NS::TfToken const& typeId, PXR_NS::SdfPath const& sprimId) override;
    PXR_NS::HdSprim *CreateFallbackSprim(PXR_NS::TfToken const& typeId) override;
    void DestroySprim(PXR_NS::HdSprim *sprim) override;

    PXR_NS::HdBprim *CreateBprim(PXR_NS::TfToken const& typeId, PXR_NS::SdfPath const& bprimId) override;
    PXR_NS::HdBprim *CreateFallbackBprim(PXR_NS::TfToken const& typeId) override;
    void DestroyBprim(PXR_NS::HdBprim *bprim) override;

    void CommitResources(PXR_NS::HdChangeTracker *tracker) override;

    PXR_NS::HdRenderParam *GetRenderParam() const override;

    PXR_NS::HdAovDescriptor GetDefaultAovDescriptor(PXR_NS::TfToken const& name) const override;
private:
    static const PXR_NS::TfTokenVector SUPPORTED_RPRIM_TYPES;
    static const PXR_NS::TfTokenVector SUPPORTED_SPRIM_TYPES;
    static const PXR_NS::TfTokenVector SUPPORTED_BPRIM_TYPES;

    void _Initialize();

    PXR_NS::HdResourceRegistrySharedPtr _resourceRegistry;
    HdMoonshine* _moonshine;

    HdMoonshineRenderDelegate(const HdMoonshineRenderDelegate &) = delete;
    HdMoonshineRenderDelegate &operator =(const HdMoonshineRenderDelegate &) = delete;
};


