#include "instancer.hpp"

#include "pxr/imaging/hd/sceneDelegate.h"
#include "pxr/imaging/hd/tokens.h"

#include "pxr/base/gf/vec3f.h"
#include "pxr/base/gf/vec4f.h"
#include "pxr/base/gf/matrix4d.h"
#include "pxr/base/gf/rotation.h"
#include "pxr/base/gf/quaternion.h"
#include "pxr/base/tf/staticTokens.h"

PXR_NAMESPACE_OPEN_SCOPE

HdMoonshineInstancer::HdMoonshineInstancer(HdSceneDelegate* delegate, SdfPath const& id) : HdInstancer(delegate, id) {}

HdMoonshineInstancer::~HdMoonshineInstancer() {}

void HdMoonshineInstancer::Sync(HdSceneDelegate* delegate, HdRenderParam* renderParam, HdDirtyBits* dirtyBits) {
    _UpdateInstancer(delegate, dirtyBits);

    if (HdChangeTracker::IsAnyPrimvarDirty(*dirtyBits, GetId())) {
        SdfPath const& id = GetId();
        HdPrimvarDescriptorVector primvars = delegate->GetPrimvarDescriptors(id, HdInterpolationInstance);

        for (HdPrimvarDescriptor const& pv: primvars) {
            if (HdChangeTracker::IsPrimvarDirty(*dirtyBits, id, pv.name)) {
                VtValue value = delegate->Get(id, pv.name);
                if (!value.IsEmpty()) {
                    primvarMap_[pv.name] = value;
                }
            }
        }
    }
}

 VtMatrix4dArray HdMoonshineInstancer::ComputeInstanceTransforms(SdfPath const &prototypeId) {
    GfMatrix4d instancerTransform = GetDelegate()->GetInstancerTransform(GetId());
    VtIntArray instanceIndices = GetDelegate()->GetInstanceIndices(GetId(), prototypeId);

    VtMatrix4dArray instanceTransforms(instanceIndices.size());

    VtValue translationsValue = primvarMap_[HdInstancerTokens->instanceTranslations];
    VtValue rotationsValue = primvarMap_[HdInstancerTokens->instanceRotations];
    VtValue scalesValue = primvarMap_[HdInstancerTokens->instanceScales];
    VtValue transformsValue = primvarMap_[HdInstancerTokens->instanceTransforms];

    VtVec3dArray translations;
    if (translationsValue.CanCast<VtVec3dArray>()) {
        translations = translationsValue.Cast<VtVec3dArray>().UncheckedGet<VtVec3dArray>();
    }

    VtQuatdArray rotations;
    if (rotationsValue.CanCast<VtQuatdArray>()) {
        rotations = rotationsValue.Cast<VtQuatdArray>().UncheckedGet<VtQuatdArray>();
    }

    VtVec3dArray scales;
    if (scalesValue.CanCast<VtVec3dArray>()) {
        scales = scalesValue.Cast<VtVec3dArray>().UncheckedGet<VtVec3dArray>();
    }

    VtMatrix4dArray transforms;
    if (transformsValue.CanCast<VtMatrix4dArray>()) {
        transforms = transformsValue.Cast<VtMatrix4dArray>().UncheckedGet<VtMatrix4dArray>();
    }

    for (size_t i = 0; i < instanceIndices.size(); i++) {
        int instanceIndex = instanceIndices[i];

        GfMatrix4d out = instancerTransform;

        GfMatrix4d temp;
        if (i < translations.size()) {
            temp.SetTranslate(translations[instanceIndex]);
            out = temp * out;
        }
        if (i < rotations.size()) {
            temp.SetRotate(rotations[instanceIndex]);
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

    HdInstancer *parentInstancer = GetDelegate()->GetRenderIndex().GetInstancer(GetParentId());
    VtMatrix4dArray parentTransforms = static_cast<HdMoonshineInstancer*>(parentInstancer)->ComputeInstanceTransforms(GetId());

    VtMatrix4dArray final(parentTransforms.size() * instanceTransforms.size());
    for (size_t i = 0; i < parentTransforms.size(); ++i) {
        for (size_t j = 0; j < instanceTransforms.size(); ++j) {
            final[i * instanceTransforms.size() + j] = instanceTransforms[j] * parentTransforms[i];
        }
    }

    return final;
}

PXR_NAMESPACE_CLOSE_SCOPE
