#include <cstdint>
#include <memory>
#include <optional>
#include <pxr/usd/sdr/shaderNode.h>
#include <pxr/usd/sdr/shaderProperty.h>
#include <pxr/usd/sdr/registry.h>

#include <pxr/imaging/hio/image.h>

#include "material.hpp"

#include "moonshine.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
    (UsdPreviewSurface)
    (diffuseColor)
    (emissiveColor)
    (normal)
    (roughness)
    (metallic)
    (ior)
    (useSpecularWorkflow)
);

HdMoonshineMaterial::HdMoonshineMaterial(const SdfPath& id, const HdMoonshineRenderParam& renderParam) : HdMaterial(id) {
    // create a handle now so it is valid for the lifetime of the object and can be used whenever
    _handle = HdMoonshineCreateMaterial(renderParam._moonshine, Material {
        .normal = renderParam._up,
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

std::optional<TextureFormat> usdFormatToMsneFormat(HioFormat format) {
    if (format == HioFormatFloat16Vec3) {
        return TextureFormat::f16x4;
    } else if (format == HioFormatUNorm8Vec4srgb) {
        return TextureFormat::u8x4_srgb;
    } else if (format == HioFormatUNorm8Vec3srgb) {
        return TextureFormat::u8x4_srgb;
    } else {
        return std::nullopt;
    }
}

void rgbToRgba(std::unique_ptr<uint8_t[]>& data, size_t pixel_count, size_t src_bytes_per_pixel, size_t dst_bytes_per_pixel) {
    for (size_t i = pixel_count - 1; i-- > 0;) {
        for (size_t j = 0; j < src_bytes_per_pixel; j++) {
            data[dst_bytes_per_pixel * i + j] = data[src_bytes_per_pixel * i + j];
        }
    }
}

std::optional<ImageHandle> makeTexture(HdMoonshine* msne, VtValue value, std::string const& debug_name) {
    if (value.IsHolding<SdfAssetPath>()) {
        auto image = HioImage::OpenForReading(value.Get<SdfAssetPath>().GetResolvedPath());
        std::optional<TextureFormat> format = usdFormatToMsneFormat(image->GetFormat());
        if (!format) {
            TF_CODING_ERROR("unknown format %u", image->GetFormat());
            return std::nullopt;
        }

        HioImage::StorageSpec spec;
        spec.width  = image->GetWidth();
        spec.height = image->GetHeight();
        spec.format = image->GetFormat();
        spec.flipped = true; // moonshine expects flipped UVs which is equivalent to flipping here
        size_t imageSize = spec.width * spec.height * image->GetBytesPerPixel();
        // moonshine does not support RGB formats so possibly allocate enough space to
        // convert to RBGA in place
        if (imageSize % 3 == 0) {
            imageSize = (imageSize / 3) * 4;
        }
        std::unique_ptr<uint8_t[]> data = std::make_unique<uint8_t[]>(imageSize);
        spec.data = data.get();
        image->Read(spec);

        // possibly pad to RGBA
        if (image->GetBytesPerPixel() % 3 == 0) {
            rgbToRgba(data, spec.width * spec.height, image->GetBytesPerPixel(), (image->GetBytesPerPixel() / 3) * 4);
        }

        Extent2D extent = Extent2D {
            .width = static_cast<uint32_t>(spec.width),
            .height = static_cast<uint32_t>(spec.height),
        };
        return HdMoonshineCreateRawTexture(msne, data.get(), extent, format.value(), (debug_name + " texture").c_str());
    } else if (value.IsHolding<GfVec3f>()) {
        GfVec3f vec = value.Get<GfVec3f>();
        return HdMoonshineCreateSolidTexture3(msne, F32x3 { .x = vec[0], .y = vec[1], .z = vec[2] }, (debug_name + " f32x3").c_str());
    } else if (value.IsHolding<float>()) {
        float val = value.Get<float>();
        return HdMoonshineCreateSolidTexture1(msne, val, (debug_name + " float").c_str());
    } else {
        TF_CODING_ERROR("unknown value type %s", value.GetTypeName().c_str());
        return std::nullopt;
    }
}

bool SetTextureBasedOnValueAndName(HdMoonshine* msne, MaterialHandle handle, TfToken name, VtValue value, std::string const& debug_name) {
    if (name == _tokens->ior) {
        float ior = value.Get<float>();
        HdMoonshineSetMaterialIOR(msne, handle, ior);
        return true;
    } else {
        // silently fail on unsupported
        if (name == _tokens->useSpecularWorkflow) {
            return true;
        }

        std::optional<ImageHandle> maybe_texture = makeTexture(msne, value, debug_name + " " + name.GetString());
        if (!maybe_texture) {
            TF_CODING_ERROR("could not parse texture %s", (debug_name + " " + name.GetString()).c_str());
            return false;
        }
        ImageHandle texture = maybe_texture.value();

        if (name == _tokens->diffuseColor) {
            HdMoonshineSetMaterialColor(msne, handle, texture);
        } else if (name == _tokens->emissiveColor) {
            HdMoonshineSetMaterialEmissive(msne, handle, texture);
        } else if (name == _tokens->normal) {
            HdMoonshineSetMaterialNormal(msne, handle, texture);
        } else if (name == _tokens->roughness) {
            HdMoonshineSetMaterialRoughness(msne, handle, texture);
        } else if (name == _tokens->metallic) {
            HdMoonshineSetMaterialMetalness(msne, handle, texture);
        }

        return true;
    }
}

void HdMoonshineMaterial::Sync(HdSceneDelegate* sceneDelegate, HdRenderParam* hdRenderParam, HdDirtyBits* dirtyBits) {
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

                TfToken sdrRole(upstreamSdr->GetRole());
                if (sdrRole == SdrNodeRole->Texture) {
                    TfToken fileProperty = upstreamSdr->GetAssetIdentifierInputNames()[0];
                    VtValue value = upstreamNode.parameters.find(fileProperty)->second;
                    SetTextureBasedOnValueAndName(msne, _handle, inputName, value, id.GetString());
                } else {
                    TF_CODING_ERROR("%s unknown connection %s: %s", id.GetText(), inputName.GetText(), upstreamSdr->GetRole().c_str());
                }
            } else if (paramIt != node.parameters.end()) {
                VtValue value = paramIt->second;
                SetTextureBasedOnValueAndName(msne, _handle, inputName, value, id.GetString() + " parameter");
            } else {
                SdrShaderPropertyConstPtr const& input = sdrNode->GetShaderInput(inputName);
                VtValue value = input->GetDefaultValue();
                SetTextureBasedOnValueAndName(msne, _handle, inputName, value, id.GetString() + " default");
            }
        }

        *dirtyBits = *dirtyBits & ~DirtyBits::DirtyParams;
    }

    if (!HdChangeTracker::IsClean(*dirtyBits)) {
        TF_CODING_ERROR("Dirty bits %s of %s were ignored!", HdChangeTracker::StringifyDirtyBits(*dirtyBits).c_str(), id.GetText());
    }
}

PXR_NAMESPACE_CLOSE_SCOPE
