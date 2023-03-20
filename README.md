<div align="center">

# Moonshine

**A general purpose GPU ray traced renderer built with Zig + Vulkan**
</div>

[![A bathroom scene rendered with moonshine](https://repository-images.githubusercontent.com/378788480/b9ad3836-4558-43f6-82ed-6668d99399b4)](https://blendswap.com/blend/12584)
*Salle de bain by nacimus, rendered with Moonshine*

### Features
* Binaries
    * offline -- a headless offline renderer
    * online -- a real-time windowed renderer, interactive features WIP
* Light Transport
    * Global Illumination
    * Direct light sampling with multiple importance sampling for all lights and materials
* Lights
    * 360° environment maps
    * Emissive meshes 
* Materials
    * Standard PBR with metallic + roughness
    * Mirror
    * Glass

### Dependencies
#### Build
* zig `0.11.0-dev.2168+322ace70f`
* DirectXShaderCompiler
* For the online (real-time) renderer:
  * For Linux (Ubuntu, similar on others):
      * For Wayland: `wayland-protocols` `libwayland-dev` `libxkbcommon-dev`
      * For X11: `libxcursor-dev` `libxrandr-dev` `libxinerama-dev` `libxi-dev`
  * Should work on Windows without more dependencies
#### Run
* A GPU supporting Vulkan ray tracing


### // TODO
* Debug/dev speed
  * Hot shader reload
* Feature
  * Bloom
  * Tonemapping
  * HDR display
  * Figure out proper way to do whole shader binding thing -- how to avoid globals?
  * More camera models
    * Orthographic
  * Materials
    * Metal
    * Rough metal
    * Rough glass
    * Plastic
    * Rough plastic
    * Mix
    * Layer
* Code
  * Make sure we have all necessary `errdefer`s
  * Proper memory allocation interface
  * Reduce unnecessary copying

### Current jankiness
* Asset system
  * Currently, one can either construct a scene manually with code or very inefficiently import glb
  * Ideal would be to have custom scene description format that can be quickly deserialzed
    * An Blender export addon for this format, so other formats don't need to be supported in engine directly
    * I think this custom format would make destinctions between scene stuff and staging stuff. It would only contain actual information about the world, but not stuff like camera position, that would be separate
* Light system
  * Currently, only support skybox and mesh lights, which I think makes sense
    * Both explicitly sampled using the alias method built on CPU
  * But we'd like to have more dynamic meshes, which means we should mesh sampling build sampling stuff on GPU
    * Not sure about proper route -- build inversion sampler on GPU in compute?
* Memory management
  * A lot of unncessary copying in scene construction at the moment
    * Filesystem to RAM
    * RAM to staging buffer
    * Staging buffer to GPU
  * Ideally this can be vastly minimized, depending on hardware
    * At most should be doing filesystem to staging buffer
    * On some machines, can do filesystem to GPU directly
* Destruction queue needs work

### Some notes about conventions, as idk where else to put them:
* `+y` is up
* phi is azimuthal angle (0-2pi) and theta is polar angle (0-pi)

### Some light reading
- [Importance sampling](https://computergraphics.stackexchange.com/q/4979)
- [Explicit light sampling](https://computergraphics.stackexchange.com/q/5152)
- [Multiple importance sampling](https://graphics.stanford.edu/courses/cs348b-03/papers/veach-chapter9.pdf)
- [Microfacets](https://agraphicsguy.wordpress.com/2015/11/01/sampling-microfacet-brdf/)
- [Actual materials](https://github.com/wdas/brdf) - ton of BRDF examples, in **CODE**!
- [Better sky](https://sebh.github.io/publications/egsr2020.pdf)

### License

This project is licensed under the AGPL.
