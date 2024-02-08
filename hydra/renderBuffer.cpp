#include "renderBuffer.hpp"
#include "moonshine.h"
#include "renderDelegate.hpp"

#include "pxr/imaging/hd/renderBuffer.h"
#include "pxr/imaging/hd/sceneDelegate.h"
#include "pxr/imaging/hd/renderIndex.h"
#include "pxr/base/gf/vec3i.h"

#include <cstdint>

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineRenderBuffer::HdMoonshineRenderBuffer(SdfPath const& id, HdMoonshineRenderDelegate* renderDelegate) : HdRenderBuffer(id), _renderDelegate(renderDelegate) {}

HdMoonshineRenderBuffer::~HdMoonshineRenderBuffer() = default;

void HdMoonshineRenderBuffer::_Deallocate() {} // TODO

bool HdMoonshineRenderBuffer::Allocate(GfVec3i const& dimensions, HdFormat format, bool multiSampled)
{
    _width = dimensions[0];
    _height = dimensions[1];

    _sensor = HdMoonshineCreateSensor(_renderDelegate->_moonshine, Extent2D { .width = _width, .height = _height });
    _data =  reinterpret_cast<uint8_t*>(HdMoonshineGetSensorData(_renderDelegate->_moonshine, _sensor));

    return true;
}

void HdMoonshineRenderBuffer::Resolve() {}

PXR_NAMESPACE_CLOSE_SCOPE
