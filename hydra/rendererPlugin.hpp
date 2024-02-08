#pragma once

#include "pxr/imaging/hd/rendererPlugin.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshinePlugin final : public HdRendererPlugin
{
public:
    HdMoonshinePlugin() = default;
    ~HdMoonshinePlugin() = default;
    HdRenderDelegate* CreateRenderDelegate() override;
    HdRenderDelegate* CreateRenderDelegate(HdRenderSettingsMap const& settingsMap) override;
    void DeleteRenderDelegate(HdRenderDelegate *renderDelegate) override;
    bool IsSupported(bool gpuEnabled) const override;
private:
    HdMoonshinePlugin(const HdMoonshinePlugin&) = delete;
    HdMoonshinePlugin &operator =(const HdMoonshinePlugin&) = delete;
};

PXR_NAMESPACE_CLOSE_SCOPE
