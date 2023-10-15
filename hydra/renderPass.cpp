#include "renderPass.hpp"

#include <pxr/imaging/hd/renderPassState.h>

#include <iostream>

HdMoonshineRenderPass::HdMoonshineRenderPass(PXR_NS::HdRenderIndex *index, PXR_NS::HdRprimCollection const &collection) : HdRenderPass(index, collection) {
    std::cout << "Creating renderPass" << std::endl;
}

HdMoonshineRenderPass::~HdMoonshineRenderPass() {
    std::cout << "Destroying renderPass" << std::endl;
}

void HdMoonshineRenderPass::_Execute(PXR_NS::HdRenderPassStateSharedPtr const& renderPassState, PXR_NS::TfTokenVector const& renderTags) {
    std::cout << "=> Execute RenderPass" << std::endl;
}
