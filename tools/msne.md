# Moonshine Scene File Format Specification

Moonshine scenes are stored in the MSNE fileformat. This is a little-endian binary file with a `.msne` extension. It is designed for fast deserialization -- one can pass through it once and copy all necessary data completely sequentially.

Each MSNE file consists of:
* a u32 magic number, equal to 0x4D534E45 (`MSNE`).
* a material list
    * a list of textures
        * a u32 total texture count
        * if total texture count is not zero:
            * a u32 1x1 texture count
            * for each 1x1 texture
                * 1 f32 value
            * a u32 2x2 texture count
            * for each 2x2 texture
                * 2 f32 values
            * a u32 3x3 texture count
            * for each 3x3 texture
                * 3 f32 values
            * a u32 DDS texture count
            * for each DDS texture
                * an embedded DDS file
    * for each material variant, in variant name alphabetical order
        * if the variant is not zero size
            * a u32 variant instance count
                * for each variant instance
                    * the variant data
    * a u32 material count
    * for each material
        * a u32 normal texture index
        * a u32 emissive texture index
        * a u32 material variant type (integers corresponding to variant names in alphabetical order)
        * a u64 material variant index
* a mesh list
    * a u32 mesh count
    * for each mesh
        * a u32 index count
        * for each index
            * 3 u32 values
        * a u32 vertex count
        * for each (vertex count) position
            * 3 f32 values
        * an 8-bit boolean indicating whether this mesh has normals
        * if true:
            * for each (vertex count) normal
                * 3 f32 values
        * an 8-bit boolean indicating whether this mesh has texcoords
        * if true:
            * for each (vertex count) texcoord
                * 2 f32 values
* a heirarchy
    * a u32 instance count
    * for each instance
        * a 12 f32 transform
        * an 8-bit boolean indicating visbility
        * a u32 geometry count
        * for each geometry
            * a u32 mesh index
            * a u32 material index
            * a 32-bit boolean indicating whether this geometry is explicitly sampled for emitted light
* camera
    * 3 f32 origin
    * 3 f32 forward
    * 3 f32 up
    * f32 vfov (radians)
    * f32 aspect
    * f32 aperture
    * f32 focus distance

### TODO
* actually specify material types rather than "alphabetical order"
* compression?
    * currently we can almost just memcpy the whole thing -- would RLE be faster or just smaller?
* non-u32 mesh indices?