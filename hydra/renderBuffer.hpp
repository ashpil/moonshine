#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/renderBuffer.h"
#include "renderDelegate.hpp"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderBuffer : public HdRenderBuffer
{
public:
    HdMoonshineRenderBuffer(SdfPath const& id, HdMoonshineRenderDelegate* renderDelegate);
    ~HdMoonshineRenderBuffer() override;

    bool Allocate(GfVec3i const& dimensions, HdFormat format, bool multiSampled) override;

    unsigned int GetWidth() const override { return _width; }
    unsigned int GetHeight() const override { return _height; }
    unsigned int GetDepth() const override { return 1; }
    HdFormat GetFormat() const override { return HdFormatFloat32Vec4; }
    bool IsMultiSampled() const override { return false; }

    void* Map() override {
        return _data;
    }

    void Unmap() override {}

    bool IsMapped() const override {
        return false;
    }

    bool IsConverged() const override {
        return false;
    }

    void Resolve() override;

    SensorHandle _sensor;
private:
    void _Deallocate() override;

    HdMoonshineRenderDelegate* _renderDelegate;
    unsigned int _width;
    unsigned int _height;
    uint8_t* _data = nullptr;
};

PXR_NAMESPACE_CLOSE_SCOPE
