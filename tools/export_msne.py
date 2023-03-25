# Blender exporter for the Moonshine scene file format
# AGPL

bl_info = {
    "name": "Moonshine scene format exporter",
    "author": "ashpil",
    "blender": (3, 0, 0),
    "location": "File > Export",
    "description": "Export moonshine scene data",
    "category": "Import-Export",
}

import bpy
import struct
from mathutils import *

def write_some_data(context, filepath):
    def write_u32(file, u32):
        file.write(u32.to_bytes(length=4, byteorder='little'))

    def write_u64(file, u64):
        file.write(u64.to_bytes(length=8, byteorder='little'))

    def write_bool(file, bool):
        file.write(bytearray(struct.pack("<?", bool)))

    def write_f32(file, f32):
        file.write(bytearray(struct.pack("<f", f32)))
        
    with open(filepath, 'wb') as file:
        file.write(b"MSNE")
        # MATERIALS
        # textures
        write_u32(file, 2) # total texture count
        write_u32(file, 0) # 1x1 texture count
        write_u32(file, 1) # 2x2 texture count
        write_f32(file, 0.5)
        write_f32(file, 0.5)
        write_u32(file, 1) # 3x3 texture count
        write_f32(file, 0.0)
        write_f32(file, 0.0)
        write_f32(file, 0.0)
        write_u32(file, 0) # dds texture count
        # material variants
        write_u32(file, 0) # glass count
        write_u32(file, 0) # lambert count
        # write_u32(file, 1) # perfect mirror count
        write_u32(file, 0) # standard pbr count
        # materials
        write_u32(file, 1) # material count
        write_u32(file, 0) # normal texture index
        write_u32(file, 1) # emissive texture index
        write_u64(file, 2) # material variant type
        write_u64(file, 0) # material variant index
        # MESHES
        meshes = set([ obj.data for obj in context.scene.objects if obj.type == 'MESH' ])
        write_u32(file, len(meshes)) # mesh count
        for mesh in meshes:
            write_u32(file, len(mesh.loop_triangles)) # mesh index count
            for triangle in mesh.loop_triangles: # for each index
                write_u32(file, mesh.loops[triangle.loops[0]].vertex_index)
                write_u32(file, mesh.loops[triangle.loops[1]].vertex_index)
                write_u32(file, mesh.loops[triangle.loops[2]].vertex_index)

            write_u32(file, len(mesh.vertices)) # mesh index count
            for vertex in mesh.vertices: # for each vertex
                write_f32(file, vertex.co[0])
                write_f32(file, vertex.co[1])
                write_f32(file, vertex.co[2])

            write_bool(file, False) # if normals
            write_bool(file, False) # if texcoords
        # HEIRARCHY
        objects = [ obj for obj in context.scene.objects if obj.type == 'MESH' ]
        write_u32(file, len(objects)) # instance count
        # TODO: multi-level hierarchies
        for object in objects:
            # transform matrix
            for v in object.matrix_world[0:3]:
                for el in v:
                    write_f32(file, el)
            write_bool(file, True) # visibility
            write_u32(file, 1) # geometry count
            write_u32(file, 0) # mesh index
            write_u32(file, 0) # material index
            write_u32(file, 0) # sampled bool
        # CAMERA
        assert len([ obj for obj in context.scene.objects if obj.type == 'CAMERA' ]) == 1, "Must have exactly one camera"
        camera = context.scene.camera
        # origin
        origin = camera.matrix_world @ Vector((0, 0, 0, 1))
        write_f32(file, origin[0])
        write_f32(file, origin[1])
        write_f32(file, origin[2])
        # forward
        forward = camera.matrix_world.to_quaternion() @ Vector((0, 0, -1))
        write_f32(file, forward[0])
        write_f32(file, forward[1])
        write_f32(file, forward[2])
        # up
        up = camera.matrix_world.to_quaternion() @ Vector((0, 1, 0))
        write_f32(file, up[0])
        write_f32(file, up[1])
        write_f32(file, up[2])
        # vfov
        write_f32(file, camera.data.angle_y)
        # aspect
        write_f32(file, context.scene.render.resolution_x / context.scene.render.resolution_y)
        # aperture
        aperture = 0.0 if not camera.data.dof.use_dof else camera.data.lens / (2 * 1000 * camera.data.dof.aperture_fstop)
        write_f32(file, aperture)
        # focus distance
        write_f32(file, camera.data.dof.focus_distance)
        

    return {'FINISHED'}


# ExportHelper is a helper class, defines filename and
# invoke() function which calls the file selector.
from bpy_extras.io_utils import ExportHelper
from bpy.props import StringProperty, BoolProperty, EnumProperty
from bpy.types import Operator


class MoonshineExporter(Operator, ExportHelper):
    """Export current scene into the Moonshine format"""
    bl_idname = "export_scene.msne"
    bl_label = "Export Moonshine"

    filename_ext = ".msne" # ExportHelper mixin class uses this

    filter_glob: StringProperty(default="*.msne", options={'HIDDEN'})

    def execute(self, context):
        return write_some_data(context, self.filepath)


def menu_func_export(self, context):
    self.layout.operator(MoonshineExporter.bl_idname, text="Moonshine (.msne)")

def register():
    bpy.utils.register_class(MoonshineExporter)
    bpy.types.TOPBAR_MT_file_export.append(menu_func_export)

def unregister():
    bpy.utils.unregister_class(MoonshineExporter)
    bpy.types.TOPBAR_MT_file_export.remove(menu_func_export)


if __name__ == "__main__":
    register()

    # test call
    bpy.ops.export_scene.msne('INVOKE_DEFAULT')
