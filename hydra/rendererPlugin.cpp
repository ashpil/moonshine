#include "rendererPlugin.hpp"
#include "renderDelegate.hpp"

#include "pxr/imaging/hd/rendererPluginRegistry.h"

PXR_NAMESPACE_OPEN_SCOPE
TF_REGISTRY_FUNCTION(TfType) {
    HdRendererPluginRegistry::Define<HdMoonshinePlugin>();
}
PXR_NAMESPACE_CLOSE_SCOPE

PXR_NS::HdRenderDelegate* HdMoonshinePlugin::CreateRenderDelegate() {
    return new HdMoonshineRenderDelegate();
}

PXR_NS::HdRenderDelegate* HdMoonshinePlugin::CreateRenderDelegate(PXR_NS::HdRenderSettingsMap const& settingsMap)
{
    return new HdMoonshineRenderDelegate(settingsMap);
}

void HdMoonshinePlugin::DeleteRenderDelegate(PXR_NS::HdRenderDelegate *renderDelegate) {
    delete renderDelegate;
}

bool HdMoonshinePlugin::IsSupported(bool gpuEnabled) const {
    return gpuEnabled;
}
