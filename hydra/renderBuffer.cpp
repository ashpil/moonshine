#include "renderBuffer.hpp"

#include "pxr/imaging/hd/renderBuffer.h"
#include "pxr/base/gf/vec3i.h"

#include <iostream>

HdMoonshineRenderBuffer::HdMoonshineRenderBuffer(PXR_NS::SdfPath const& id) : PXR_NS::HdRenderBuffer(id) {
    std::cout << "Create render buffer id=" << id << std::endl;
}

HdMoonshineRenderBuffer::~HdMoonshineRenderBuffer() = default;

void HdMoonshineRenderBuffer::_Deallocate() {
    std::cout << "Deallocate buffer" << std::endl;
}

bool HdMoonshineRenderBuffer::Allocate(PXR_NS::GfVec3i const& dimensions, PXR_NS::HdFormat format, bool multiSampled)
{
    std::cout << "Allocate buffer dimensions=" << dimensions << " format=" << format << std::endl;
    _width = dimensions[0];
    _height = dimensions[1];
    _format = format;
    _multiSampled = multiSampled;
    _buffer.resize(_width * _height * PXR_NS::HdDataSizeOfFormat(format) / 3 * 4, 0);
    return true;
}

void HdMoonshineRenderBuffer::Resolve() {
    std::cout << "Resolve buffer" << std::endl;
}
