#include "renderBuffer.hpp"
#include "moonshine.h"
#include "renderDelegate.hpp"

#include "pxr/imaging/hd/renderBuffer.h"
#include "pxr/imaging/hd/sceneDelegate.h"
#include "pxr/imaging/hd/renderIndex.h"
#include "pxr/base/gf/vec3i.h"

#include <cstdint>
#include <iostream>

HdMoonshineRenderBuffer::HdMoonshineRenderBuffer(PXR_NS::SdfPath const& id, HdMoonshineRenderDelegate* renderDelegate) : PXR_NS::HdRenderBuffer(id), _renderDelegate(renderDelegate) {
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

    _sensor = HdMoonshineCreateSensor(_renderDelegate->_moonshine, Extent2D { .width = _width, .height = _height });
    _data =  reinterpret_cast<uint8_t*>(HdMoonshineGetSensorData(_renderDelegate->_moonshine, _sensor));

    return true;
}

void HdMoonshineRenderBuffer::Resolve() {}
