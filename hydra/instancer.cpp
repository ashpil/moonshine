#include "instancer.hpp"

#include "pxr/imaging/hd/sceneDelegate.h"
#include "pxr/imaging/hd/tokens.h"

#include "pxr/base/gf/vec3f.h"
#include "pxr/base/gf/vec4f.h"
#include "pxr/base/gf/matrix4d.h"
#include "pxr/base/gf/rotation.h"
#include "pxr/base/gf/quaternion.h"
#include "pxr/base/tf/staticTokens.h"

#include <iostream>

HdMoonshineInstancer::HdMoonshineInstancer(PXR_NS::HdSceneDelegate* delegate, PXR_NS::SdfPath const& id) : PXR_NS::HdInstancer(delegate, id) {}

HdMoonshineInstancer::~HdMoonshineInstancer() {}

void HdMoonshineInstancer::Sync(PXR_NS::HdSceneDelegate* delegate, PXR_NS::HdRenderParam* renderParam, PXR_NS::HdDirtyBits* dirtyBits) {
    _UpdateInstancer(delegate, dirtyBits);

    if (PXR_NS::HdChangeTracker::IsAnyPrimvarDirty(*dirtyBits, GetId())) {
        PXR_NS::SdfPath const& id = GetId();
        PXR_NS::HdPrimvarDescriptorVector primvars = delegate->GetPrimvarDescriptors(id, PXR_NS::HdInterpolationInstance);

        for (PXR_NS::HdPrimvarDescriptor const& pv: primvars) {
            if (PXR_NS::HdChangeTracker::IsPrimvarDirty(*dirtyBits, id, pv.name)) {
                PXR_NS::VtValue value = delegate->Get(id, pv.name);
                if (!value.IsEmpty()) {
                    primvarMap_[pv.name] = value;
                }
            }
        }
    }
}

 PXR_NS::VtMatrix4dArray HdMoonshineInstancer::ComputeInstanceTransforms(PXR_NS::SdfPath const &prototypeId) {
    PXR_NS::GfMatrix4d instancerTransform = GetDelegate()->GetInstancerTransform(GetId());
    PXR_NS::VtIntArray instanceIndices = GetDelegate()->GetInstanceIndices(GetId(), prototypeId);

    PXR_NS::VtMatrix4dArray instanceTransforms(instanceIndices.size());

    PXR_NS::VtValue translationsValue = primvarMap_[PXR_NS::HdInstancerTokens->instanceTranslations];
    PXR_NS::VtValue rotationsValue = primvarMap_[PXR_NS::HdInstancerTokens->instanceRotations];
    PXR_NS::VtValue scalesValue = primvarMap_[PXR_NS::HdInstancerTokens->instanceScales];
    PXR_NS::VtValue transformsValue = primvarMap_[PXR_NS::HdInstancerTokens->instanceTransforms];

    PXR_NS::VtVec3dArray translations;
    if (translationsValue.CanCast<PXR_NS::VtVec3dArray>()) {
        translations = translationsValue.Cast<PXR_NS::VtVec3dArray>().UncheckedGet<PXR_NS::VtVec3dArray>();
    }

    PXR_NS::VtQuatdArray rotations;
    if (rotationsValue.CanCast<PXR_NS::VtQuatdArray>()) {
        rotations = rotationsValue.Cast<PXR_NS::VtQuatdArray>().UncheckedGet<PXR_NS::VtQuatdArray>();
    }

    PXR_NS::VtVec3dArray scales;
    if (scalesValue.CanCast<PXR_NS::VtVec3dArray>()) {
        scales = scalesValue.Cast<PXR_NS::VtVec3dArray>().UncheckedGet<PXR_NS::VtVec3dArray>();
    }

    PXR_NS::VtMatrix4dArray transforms;
    if (transformsValue.CanCast<PXR_NS::VtMatrix4dArray>()) {
        transforms = transformsValue.Cast<PXR_NS::VtMatrix4dArray>().UncheckedGet<PXR_NS::VtMatrix4dArray>();
    }

    for (size_t i = 0; i < instanceIndices.size(); i++) {
        int instanceIndex = instanceIndices[i];

        PXR_NS::GfMatrix4d out = instancerTransform;

        PXR_NS::GfMatrix4d temp;
        if (i < translations.size()) {
            temp.SetTranslate(translations[instanceIndex]);
            out = temp * out;
        }
        if (i < rotations.size()) {
            temp.SetRotate(rotations[instanceIndex]);
            std::cout << rotations[instanceIndex] << std::endl;
            out = temp * out;
        }
        if (i < scales.size()) {
            temp.SetScale(scales[instanceIndex]);
            out = temp * out;
        }
        if (i < transforms.size()) {
            temp = transforms[instanceIndex];
            out = temp * out;
        }

        instanceTransforms[i] = out;
    }

    if (GetParentId().IsEmpty()) {
        return instanceTransforms;
    }

    PXR_NS::HdInstancer *parentInstancer = GetDelegate()->GetRenderIndex().GetInstancer(GetParentId());
    PXR_NS::VtMatrix4dArray parentTransforms = static_cast<HdMoonshineInstancer*>(parentInstancer)->ComputeInstanceTransforms(GetId());

    PXR_NS::VtMatrix4dArray final(parentTransforms.size() * instanceTransforms.size());
    for (size_t i = 0; i < parentTransforms.size(); ++i) {
        for (size_t j = 0; j < instanceTransforms.size(); ++j) {
            final[i * instanceTransforms.size() + j] = instanceTransforms[j] * parentTransforms[i];
        }
    }

    return final;
}
