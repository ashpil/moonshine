#pragma once

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineRenderParam final : public HdRenderParam
{
public:
    HdMoonshineRenderParam(HdMoonshine* moonshine) : _moonshine(moonshine) {}

    HdMoonshine* _moonshine;
};

PXR_NAMESPACE_CLOSE_SCOPE