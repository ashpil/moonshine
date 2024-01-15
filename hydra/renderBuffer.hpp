#pragma once

#include "moonshine.h"

#include "pxr/pxr.h"
#include "pxr/imaging/hd/renderBuffer.h"
#include "renderDelegate.hpp"

#include <iostream>

class HdMoonshineRenderBuffer : public PXR_NS::HdRenderBuffer
{
public:
    HdMoonshineRenderBuffer(PXR_NS::SdfPath const& id, HdMoonshineRenderDelegate* renderDelegate);
    ~HdMoonshineRenderBuffer() override;

    bool Allocate(PXR_NS::GfVec3i const& dimensions, PXR_NS::HdFormat format, bool multiSampled) override;

    unsigned int GetWidth() const override { return _width; }
    unsigned int GetHeight() const override { return _height; }
    unsigned int GetDepth() const override { return 1; }
    PXR_NS::HdFormat GetFormat() const override { return PXR_NS::HdFormatFloat32Vec4; }
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
