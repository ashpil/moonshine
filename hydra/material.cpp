#include <pxr/usd/sdr/shaderNode.h>
#include <pxr/usd/sdr/shaderProperty.h>
#include <pxr/usd/sdr/registry.h>

#include "material.hpp"

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
    (UsdPreviewSurface)
    (diffuseColor)
);

HdMoonshineMaterial::HdMoonshineMaterial(const SdfPath& id, const HdMoonshineRenderParam& renderParam) : HdMaterial(id) {
    // create a handle now so it is valid for the lifetime of the object and can be used whenever
    _handle = HdMoonshineCreateMaterial(renderParam._moonshine, Material {
        .normal = renderParam._grey2,
        .emissive = renderParam._black3,
        .color = renderParam._grey3,
        .metalness = renderParam._black1,
        .roughness = renderParam._white1,
        .ior = 1.5,
    });
}

HdMoonshineMaterial::~HdMoonshineMaterial() {}

HdDirtyBits HdMoonshineMaterial::GetInitialDirtyBitsMask() const {
    return DirtyBits::DirtyParams;
}

void HdMoonshineMaterial::Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* hdRenderParam, HdDirtyBits* dirtyBits)
{
    SdfPath const& id = GetId();

    HdMoonshineRenderParam* renderParam = static_cast<HdMoonshineRenderParam*>(hdRenderParam);
    HdMoonshine* msne = renderParam->_moonshine;

    if (*dirtyBits & DirtyBits::DirtyParams) {
        const VtValue& resource = sceneDelegate->GetMaterialResource(id);

        if (!resource.IsHolding<HdMaterialNetworkMap>())
        {
            TF_CODING_ERROR("Unknown resource type of %s!", id.GetText());
            return;
        }

        const HdMaterialNetwork2& network = HdConvertToHdMaterialNetwork2(resource.UncheckedGet<HdMaterialNetworkMap>());

        // find node connecting to surface output
        auto const& terminalConnIt = network.terminals.find(HdMaterialTerminalTokens->surface);
        if (terminalConnIt == network.terminals.end()) {
            TF_CODING_ERROR("did not find suface connection for %s", id.GetText());
            return;
        }

        HdMaterialConnection2 const& connection = terminalConnIt->second;
        SdfPath const& terminalPath = connection.upstreamNode;
        auto const& terminalIt = network.nodes.find(terminalPath);
        const auto& node = terminalIt->second;

        // parse UsdPreviewSurface
        if (node.nodeTypeId != _tokens->UsdPreviewSurface) {
            TF_CODING_ERROR("don't know what to do with node %s in %s", node.nodeTypeId.GetText(), id.GetText());
            return;
        }

        SdrRegistry& shaderReg = SdrRegistry::GetInstance();
        SdrShaderNodeConstPtr const sdrNode = shaderReg.GetShaderNodeByIdentifier(node.nodeTypeId);
        for (TfToken const& inputName : sdrNode->GetInputNames()) {
            auto const& conIt = node.inputConnections.find(inputName);
            auto const& paramIt = node.parameters.find(inputName);
            if (conIt != node.inputConnections.end()) {
                HdMaterialConnection2 const& con = conIt->second.front();

                auto const& upIt = network.nodes.find(con.upstreamNode);
                HdMaterialNode2 const& upstreamNode = upIt->second;
                SdrShaderNodeConstPtr upstreamSdr = shaderReg.GetShaderNodeByIdentifier(upstreamNode.nodeTypeId);

                TF_CODING_ERROR("%s unhandled connection %s: %s", id.GetText(), inputName.GetText(), upstreamSdr->GetRole().c_str());
            } else if (paramIt != node.parameters.end()) {
                VtValue value = paramIt->second;
                if (inputName == _tokens->diffuseColor) {
                    GfVec3f color = value.Get<GfVec3f>();
                    ImageHandle color_tex = HdMoonshineCreateSolidTexture3(msne, F32x3 { .x = color[0], .y = color[1], .z = color[2] }, "color");
                    HdMoonshineSetMaterialColor(msne, _handle, color_tex);
                } else {
                    TF_CODING_ERROR("%s unhandled parameter %s: %s", id.GetText(), inputName.GetText(), value.GetTypeName().c_str());
                }
            } else {
                TF_CODING_ERROR("%s unhandled default %s", id.GetText(), inputName.GetText());
            }
        }

        *dirtyBits = *dirtyBits & ~DirtyBits::DirtyParams;
    }

    if (!HdChangeTracker::IsClean(*dirtyBits)) {
        TF_CODING_ERROR("Dirty bits %s of %s were ignored!", HdChangeTracker::StringifyDirtyBits(*dirtyBits).c_str(), id.GetText());
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
