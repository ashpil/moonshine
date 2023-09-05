#pragma once

#include "pxr/imaging/hd/rendererPlugin.h"

class HdMoonshinePlugin final : public PXR_NS::HdRendererPlugin 
{
public:
    HdMoonshinePlugin() = default;
    ~HdMoonshinePlugin() = default;
    PXR_NS::HdRenderDelegate* CreateRenderDelegate() override;
    PXR_NS::HdRenderDelegate* CreateRenderDelegate(PXR_NS::HdRenderSettingsMap const& settingsMap) override;
    void DeleteRenderDelegate(PXR_NS::HdRenderDelegate *renderDelegate) override;
    bool IsSupported(bool gpuEnabled) const override;
private:
    HdMoonshinePlugin(const HdMoonshinePlugin&) = delete;
    HdMoonshinePlugin &operator =(const HdMoonshinePlugin&) = delete;
};
