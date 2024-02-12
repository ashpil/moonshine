#pragma once

#include <memory>

#include <pxr/pxr.h>
#include <pxr/imaging/hd/renderDelegate.h>
#include <pxr/imaging/hd/resourceRegistry.h>
#include <pxr/base/tf/staticTokens.h>

#include "renderParam.hpp"

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderDelegate final : public HdRenderDelegate
{
public:
    HdMoonshineRenderDelegate();
    HdMoonshineRenderDelegate(HdRenderSettingsMap const& settingsMap);
    ~HdMoonshineRenderDelegate();

    const TfTokenVector &GetSupportedRprimTypes() const override;
    const TfTokenVector &GetSupportedSprimTypes() const override;
    const TfTokenVector &GetSupportedBprimTypes() const override;

    HdResourceRegistrySharedPtr GetResourceRegistry() const override;

    HdRenderPassSharedPtr CreateRenderPass(HdRenderIndex *index, HdRprimCollection const& collection) override;

    HdInstancer *CreateInstancer(HdSceneDelegate *delegate, SdfPath const& id) override;
    void DestroyInstancer(HdInstancer *instancer) override;

    HdRprim *CreateRprim(TfToken const& typeId, SdfPath const& rprimId) override;
    void DestroyRprim(HdRprim *rPrim) override;

    HdSprim *CreateSprim(TfToken const& typeId, SdfPath const& sprimId) override;
    HdSprim *CreateFallbackSprim(TfToken const& typeId) override;
    void DestroySprim(HdSprim *sprim) override;

    HdBprim *CreateBprim(TfToken const& typeId, SdfPath const& bprimId) override;
    HdBprim *CreateFallbackBprim(TfToken const& typeId) override;
    void DestroyBprim(HdBprim *bprim) override;

    void CommitResources(HdChangeTracker *tracker) override;

    HdRenderParam *GetRenderParam() const override;

    HdAovDescriptor GetDefaultAovDescriptor(TfToken const& name) const override;
    HdMoonshine* _moonshine;
private:
    static const TfTokenVector SUPPORTED_RPRIM_TYPES;
    static const TfTokenVector SUPPORTED_SPRIM_TYPES;
    static const TfTokenVector SUPPORTED_BPRIM_TYPES;

    void _Initialize();

    HdResourceRegistrySharedPtr _resourceRegistry;
    std::unique_ptr<HdMoonshineRenderParam> _renderParam;

    HdMoonshineRenderDelegate(const HdMoonshineRenderDelegate &) = delete;
    HdMoonshineRenderDelegate &operator =(const HdMoonshineRenderDelegate &) = delete;
};

PXR_NAMESPACE_CLOSE_SCOPE