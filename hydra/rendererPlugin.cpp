#include "rendererPlugin.hpp"
#include "renderDelegate.hpp"

#include "pxr/imaging/hd/rendererPluginRegistry.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_REGISTRY_FUNCTION(TfType) {
    HdRendererPluginRegistry::Define<HdMoonshinePlugin>();
}

HdRenderDelegate* HdMoonshinePlugin::CreateRenderDelegate() {
    return new HdMoonshineRenderDelegate();
}

HdRenderDelegate* HdMoonshinePlugin::CreateRenderDelegate(HdRenderSettingsMap const& settingsMap)
{
    return new HdMoonshineRenderDelegate(settingsMap);
}

void HdMoonshinePlugin::DeleteRenderDelegate(HdRenderDelegate *renderDelegate) {
    delete renderDelegate;
}

bool HdMoonshinePlugin::IsSupported(bool gpuEnabled) const {
    return gpuEnabled;
}

PXR_NAMESPACE_CLOSE_SCOPE