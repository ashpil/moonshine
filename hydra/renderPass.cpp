#include "moonshine.h"

#include "camera.hpp"
#include "renderPass.hpp"
#include "renderBuffer.hpp"
#include "renderDelegate.hpp"

#include <pxr/imaging/hd/renderPassState.h>
#include <pxr/imaging/hd/tokens.h>

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineRenderPass::HdMoonshineRenderPass(HdRenderIndex *index, HdRprimCollection const &collection) : HdRenderPass(index, collection) {}

HdMoonshineRenderPass::~HdMoonshineRenderPass() {}

void HdMoonshineRenderPass::_Execute(HdRenderPassStateSharedPtr const& renderPassState, TfTokenVector const& renderTags) {
    for (const auto aov : renderPassState->GetAovBindings()) {
        if (aov.aovName == HdAovTokens->color) {
            HdRenderIndex* renderIndex = GetRenderIndex();
            HdMoonshineRenderDelegate* renderDelegate = static_cast<HdMoonshineRenderDelegate*>(renderIndex->GetRenderDelegate());
            const HdMoonshineCamera* camera = static_cast<const HdMoonshineCamera*>(renderPassState->GetCamera());

            HdMoonshineRenderBuffer* renderBuffer = static_cast<HdMoonshineRenderBuffer*>(aov.renderBuffer);
            HdMoonshineRender(renderDelegate->_moonshine, renderBuffer->_sensor, camera->_handle);
        }
    }
}

PXR_NAMESPACE_CLOSE_SCOPE