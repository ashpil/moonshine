# Blender add-on for moonshine
# Moonshine delegate must be in PXR_PLUGINPATH_NAME

import bpy

class MoonshineRenderEngine(bpy.types.HydraRenderEngine):
    bl_idname = 'HYDRA_MOONSHINE'
    bl_label = "Moonshine"

    bl_use_preview = True
    bl_use_gpu_context = False
    bl_use_materialx = False

    bl_delegate_id = 'HdMoonshinePlugin'

register, unregister = bpy.utils.register_classes_factory((
    MoonshineRenderEngine,
))

if __name__ == "__main__":
    register()