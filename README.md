<div align="center">

# Moonshine

**A spectral path tracer built with Zig + Vulkan**
</div>

[![A bathroom scene rendered with moonshine](https://repository-images.githubusercontent.com/378788480/b9ad3836-4558-43f6-82ed-6668d99399b4)](https://blendswap.com/blend/12584)
*Salle de bain by nacimus, rendered with Moonshine*

### Features
* Binaries
    * offline -- a headless offline renderer
    * online -- a real-time windowed renderer
    * hydra -- a hydra render delegate
* Light Transport
    * Full spectral path tracing with an arbitrary output color space
    * Direct light sampling with multiple importance sampling for all lights and materials
* Lights
    * 360° environment maps
      * Sampled via [hierarchical warping](https://pharr.org/matt/blog/2019/06/05/visualizing-env-light-warpings)
    * Emissive meshes
      * Sampled according to power via 1D [hierarchical warping](https://pharr.org/matt/blog/2019/06/05/visualizing-env-light-warpings)
* Materials
    * Standard PBR with metallic + roughness
    * Mirror
    * Glass with dispersion
* Homogeneous volumes

### Dependencies
#### Build
* zig (see version [in build.zig.zon](build.zig.zon))
* DirectXShaderCompiler
* For the online (real-time) renderer:
  * For Linux (Ubuntu, similar on others): `wayland-protocols` `libwayland-dev` `libxkbcommon-dev`
#### Run
* A GPU supporting Vulkan ray tracing

### License

This project is licensed under the AGPL.
