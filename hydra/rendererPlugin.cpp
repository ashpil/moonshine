#include "rendererPlugin.hpp"
#include "renderDelegate.hpp"

#include "pxr/imaging/hd/rendererPluginRegistry.h"

#include <iostream>

PXR_NAMESPACE_OPEN_SCOPE
TF_REGISTRY_FUNCTION(TfType) {
    HdRendererPluginRegistry::Define<HdMoonshinePlugin>();
}
PXR_NAMESPACE_CLOSE_SCOPE

PXR_NS::HdRenderDelegate* HdMoonshinePlugin::CreateRenderDelegate() {
    std::cout << "CreateRenderDelegate" << std::endl;
    return new HdMoonshineRenderDelegate();
}

PXR_NS::HdRenderDelegate* HdMoonshinePlugin::CreateRenderDelegate(PXR_NS::HdRenderSettingsMap const& settingsMap)
{
    std::cout << "CreateRenderDelegate with settings" << std::endl;
    return new HdMoonshineRenderDelegate(settingsMap);
}

void HdMoonshinePlugin::DeleteRenderDelegate(PXR_NS::HdRenderDelegate *renderDelegate) {
    std::cout << "DeleteRenderDelegate" << std::endl;
    delete renderDelegate;
}

bool HdMoonshinePlugin::IsSupported(bool gpuEnabled) const {
    std::cout << "IsSupported " << gpuEnabled << std::endl;
    return gpuEnabled;
}
