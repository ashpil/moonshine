#pragma once

#include <pxr/imaging/hd/material.h>
#include <pxr/imaging/hd/sceneDelegate.h>

#include "renderParam.hpp"

PXR_NAMESPACE_OPEN_SCOPE

class HdMoonshineMaterial final : public HdMaterial
{
public:
    HdMoonshineMaterial(const SdfPath& id, const HdMoonshineRenderParam& renderParam);
    ~HdMoonshineMaterial() override;

public:
    HdDirtyBits GetInitialDirtyBitsMask() const override;

    void Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) override;

    MaterialHandle _handle;
};

PXR_NAMESPACE_CLOSE_SCOPE