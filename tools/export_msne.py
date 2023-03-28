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
from mathutils import *
import struct
from collections import defaultdict

def write(context, filepath: str):
    def write_u32(file, u32: int):
        file.write(u32.to_bytes(length=4, byteorder='little'))

    def write_u64(file, u64: int):
        file.write(u64.to_bytes(length=8, byteorder='little'))

    def write_bool(file, bool: bool):
        file.write(struct.pack("<?", bool))

    def write_f32(file, f32: float):
        file.write(struct.pack("<f", f32))
        
    def write_mesh(file, mesh):
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
        
        # assume if first polygon smooth then all are
        # TODO: do this in a more principled way and support non-smooth custom normals
        has_normals = mesh.polygons[0].use_smooth
        write_bool(file, has_normals) # if normals
        if has_normals:
            for normal in mesh.vertex_normals: # for each vertex
                write_f32(file, normal.vector[0])
                write_f32(file, normal.vector[1])
                write_f32(file, normal.vector[2])
        write_bool(file, False) # TODO: if texcoords
        
    def write_object(file, object, meshes, materials):
        # transformation matrix
        for v in object.matrix_world[0:3]:
            for el in v:
                write_f32(file, el)
        write_bool(file, True) # visibility
        write_u32(file, 1) # geometry count
        write_u32(file, meshes[object.data]) # mesh index
        write_u32(file, materials[object.active_material]) # material index
        write_u32(file, 0) # sampled bool

    def write_camera(file, camera):
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
        
    def find_materials(scene):
        material_map = dict()
        variants = defaultdict(lambda: [])
        materials = []
        textures1 = defaultdict(None)
        textures2 = defaultdict(None)
        textures3 = defaultdict(None)
        
        def parse_input3(material, input, name):
            assert not input.is_linked
            i3 = tuple(input.default_value[0:3])
            if i3 not in textures3:
                textures3[i3] = len(textures3)
            material[name] = textures3[i3]
        
        def parse_input1(material, input, name):
            assert not input.is_linked
            value = input.default_value
            if value not in textures1:
                textures1[value] = len(textures1)
            material[name] = textures1[value]
        
        def parse_value(material, input, name):
            assert not input.is_linked
            material[name] = input.default_value
            
        def parse_normal(material, input):
            assert not input.is_linked
            n = (0.5, 0.5)
            if n not in textures2:
                textures2[n] = len(textures2)
            material["normal"] = textures2[n]
        
        for blender_material in set([ obj.active_material for obj in scene.objects if obj.type == 'MESH' ]):
            material = {}
            penultimate = blender_material.node_tree.get_output_node('CYCLES').inputs[0].links[0].from_node
            penultimate_type = type(penultimate)
            if penultimate_type == bpy.types.ShaderNodeBsdfPrincipled:
                material["type"] = 3
                parse_input3(material, penultimate.inputs["Base Color"], "color")
                parse_input1(material, penultimate.inputs["Metallic"], "metalness")
                parse_input1(material, penultimate.inputs["Roughness"], "roughness")
                parse_value(material, penultimate.inputs["IOR"], "ior")
                parse_normal(material, penultimate.inputs["Normal"])
                
                # special case for emissive
                emission = penultimate.inputs["Emission"]
                emission_strength = penultimate.inputs["Emission Strength"]
                assert not emission.is_linked and not emission_strength.is_linked
                i3 = tuple(e * emission_strength.default_value for e in emission.default_value[0:3])
                if i3 not in textures3:
                    textures3[i3] = len(textures3)
                material["emissive"] = textures3[i3]
                
                material["idx"] = len(variants["Standard PBR"])
                variants["Standard PBR"].append(material)
            elif penultimate_type == bpy.types.ShaderNodeBsdfGlossy:
                material["type"] = 2
                parse_normal(material, penultimate.inputs["Normal"])
                
                roughness = penultimate.inputs["Roughness"]
                assert not roughness.is_linked
                assert roughness.default_value == 0, "TODO: non-perfect mirror"
                
                i3 = (0, 0, 0)
                if i3 not in textures3:
                    textures3[i3] = len(textures3)
                material["emissive"] = textures3[i3]
                
                material["idx"] = len(variants["Perfect Mirror"])
                variants["Perfect Mirror"].append(material)
            else:
                assert false, "Unknown material type!"
    
            material_map[blender_material] = len(materials)
            materials.append(material)
        return materials, material_map, variants, list(textures1), list(textures2), list(textures3)

        
    with open(filepath, 'wb') as file:
        file.write(b"MSNE")
        # MATERIALS
        materials, materials_map, variants, textures1, textures2, textures3 = find_materials(context.scene)
        print(materials)
        # textures
        total_texture_count = len(textures1) + len(textures2) + len(textures3)
        write_u32(file, total_texture_count) # total texture count
        write_u32(file, len(textures1)) # 1xf32 texture count
        for texture in textures1:
            write_f32(file, texture)
        write_u32(file, len(textures2)) # 2xf32 texture count
        for texture in textures2:
            write_f32(file, texture[0])
            write_f32(file, texture[1])
        write_u32(file, len(textures3)) # 3xf32 texture count
        for texture in textures3:
            write_f32(file, texture[0])
            write_f32(file, texture[1])
            write_f32(file, texture[2])
        write_u32(file, 0) # dds texture count
        # material variants
        write_u32(file, len(variants["Glass"])) # glass count
        for glass in variants["Glass"]:
            write_f32(file, glass["ior"])
        write_u32(file, len(variants["Lambert"])) # lambert count
        for lambert in variants["Lambert"]:
            write_u32(file, len(textures1) + len(textures2) + lambert["color"])
        # perfect mirror count, zero size
        write_u32(file, len(variants["Standard PBR"])) # standard pbr count
        for material in variants["Standard PBR"]:
            write_u32(file, len(textures1) + len(textures2) + material["color"])
            write_u32(file, material["metalness"])
            write_u32(file, material["roughness"])
            write_f32(file, material["ior"])
        # materials
        write_u32(file, len(materials)) # material count
        for material in materials:
            write_u32(file, len(textures1) + material["normal"]) # normal texture index
            write_u32(file, len(textures1) + len(textures2) + material["emissive"]) # emissive texture index
            write_u64(file, material["type"]) # material variant type
            write_u64(file, material["idx"]) # material variant index

        # MESHES
        meshes = {}
        i = 0
        for obj in context.scene.objects:
            if obj.type == 'MESH':
                if obj.data not in meshes:
                    meshes[obj.data] = i
                    i += 1

        write_u32(file, len(meshes.keys())) # mesh count
        for mesh in meshes.keys():
            write_mesh(file, mesh)

        # HEIRARCHY
        # TODO: multi-level hierarchies
        objects = [ obj for obj in context.scene.objects if obj.type == 'MESH' ]
        write_u32(file, len(objects)) # instance count
        for object in objects:
            write_object(file, object, meshes, materials_map)

        # CAMERA
        assert len([ obj for obj in context.scene.objects if obj.type == 'CAMERA' ]) == 1, "Must have exactly one camera"
        write_camera(file, context.scene.camera)
        

    return {'FINISHED'}


# ExportHelper is a helper class, defines filename and
# invoke() function which calls the file selector.
from bpy_extras.io_utils import ExportHelper
from bpy.props import StringProperty
from bpy.types import Operator


class MoonshineExporter(Operator, ExportHelper):
    """Export current scene into the Moonshine format"""
    bl_idname = "export_scene.msne"
    bl_label = "Export Moonshine"

    filename_ext = ".msne" # ExportHelper mixin class uses this

    filter_glob: StringProperty(default="*.msne", options={'HIDDEN'})

    def execute(self, context):
        return write(context, self.filepath)


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
