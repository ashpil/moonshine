#pragma once

#include "pxr/pxr.h"
#include "pxr/imaging/hd/renderBuffer.h"

#include <iostream>

class HdMoonshineRenderBuffer : public PXR_NS::HdRenderBuffer
{
public:
    HdMoonshineRenderBuffer(PXR_NS::SdfPath const& id);
    ~HdMoonshineRenderBuffer() override;

    bool Allocate(PXR_NS::GfVec3i const& dimensions, PXR_NS::HdFormat format, bool multiSampled) override;

    unsigned int GetWidth() const override { return _width; }
    unsigned int GetHeight() const override { return _height; }
    unsigned int GetDepth() const override { return 1; }
    PXR_NS::HdFormat GetFormat() const override { return _format; }
    bool IsMultiSampled() const override { return _multiSampled; }

    void* Map() override {
        std::cout << "Map buffer" << std::endl;
        return _buffer.data();
    }

    void Unmap() override {
        std::cout << "Unmap buffer" << std::endl;
    }

    bool IsMapped() const override {
        return false;
    }

    bool IsConverged() const override {
        return false;
    }

    void Resolve() override;

private:
    void _Deallocate() override;

    unsigned int _width;
    unsigned int _height;
    PXR_NS::HdFormat _format;
    bool _multiSampled;
    std::vector<uint8_t> _buffer;
};
