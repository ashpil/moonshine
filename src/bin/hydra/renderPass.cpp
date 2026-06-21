#include "moonshine.h"

#include "camera.hpp"
#include "renderPass.hpp"
#include "renderBuffer.hpp"
#include "renderDelegate.hpp"

#include <pxr/imaging/hd/changeTracker.h>
#include <pxr/imaging/hd/renderIndex.h>
#include <pxr/imaging/hd/renderPassState.h>
#include <pxr/imaging/hd/tokens.h>

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineRenderPass::HdMoonshineRenderPass(HdRenderIndex *index, HdRprimCollection const &collection) : HdRenderPass(index, collection) {}

HdMoonshineRenderPass::~HdMoonshineRenderPass() {}

bool HdMoonshineRenderPass::IsConverged() const {
    for (const auto& aov : _aovBindings) {
        const HdMoonshineRenderBuffer* renderBuffer = static_cast<const HdMoonshineRenderBuffer*>(aov.renderBuffer);
        if (renderBuffer && !renderBuffer->IsConverged()) {
            return false;
        }
    }
    return true;
}

void HdMoonshineRenderPass::_Execute(HdRenderPassStateSharedPtr const& renderPassState, TfTokenVector const& renderTags) {
    _aovBindings = renderPassState->GetAovBindings();

    HdRenderIndex* renderIndex = GetRenderIndex();
    HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex->GetRenderDelegate());
    HdMoonshine* msne = renderDelegate->_moonshine;
    const HdMoonshineCamera* camera = static_cast<const HdMoonshineCamera*>(renderPassState->GetCamera());

    const int requestedSamples = renderDelegate->GetRenderSetting<int>(HdRenderSettingsTokens->convergedSamplesPerPixel, 0);
    const unsigned int targetSamples = requestedSamples > 0 ? static_cast<unsigned int>(requestedSamples) : 0u;

    const GfMatrix4d view = renderPassState->GetWorldToViewMatrix();
    const GfMatrix4d proj = renderPassState->GetProjectionMatrix();
    const unsigned int sceneVersion = renderIndex->GetChangeTracker().GetSceneStateVersion();
    const unsigned int pipelineVersion = renderDelegate->_pipelineVersion;
    const bool changed = view != _viewMatrix || proj != _projMatrix || sceneVersion != _lastSceneVersion || pipelineVersion != _lastPipelineVersion;
    _viewMatrix = view;
    _projMatrix = proj;
    _lastSceneVersion = sceneVersion;
    _lastPipelineVersion = pipelineVersion;

    for (const auto& aov : _aovBindings) {
        if (aov.aovName != HdAovTokens->color) {
            continue;
        }

        HdMoonshineRenderBuffer* renderBuffer = static_cast<HdMoonshineRenderBuffer*>(aov.renderBuffer);
        renderBuffer->_targetSamples = targetSamples;

        if (changed) {
            HdMoonshineClearSensor(msne, renderBuffer->_sensor);
        }

        if (!renderBuffer->IsConverged()) {
            HdMoonshineRender(msne, renderBuffer->_sensor, camera->_handle);
        }
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
