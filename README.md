<div align="center">

# Moonshine

**A general purpose GPU ray traced renderer built with Zig + Vulkan**
</div>

[![A bathroom scene rendered with moonshine](https://repository-images.githubusercontent.com/378788480/b9ad3836-4558-43f6-82ed-6668d99399b4)](https://blendswap.com/blend/12584)
*Salle de bain by nacimus, rendered with Moonshine*

### Features
* Binaries
    * offline -- a headless offline renderer
    * online -- a real-time windowed renderer
    * hydra -- a hydra render delegate
* Light Transport
    * Full path tracing
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
* zig (see version [in CI](.github/workflows/build.yml))
* DirectXShaderCompiler
* For the online (real-time) renderer:
  * For Linux (Ubuntu, similar on others):
      * For Wayland: `wayland-protocols` `libwayland-dev` `libxkbcommon-dev`
      * For X11: `libxcursor-dev` `libxrandr-dev` `libxinerama-dev` `libxi-dev`
  * Should work on Windows without additional dependencies
#### Run
* A GPU supporting Vulkan ray tracing

### // TODO
* Tonemapping
* HDR display
* Cameras
  * Projection
    * Orthographic
    * Arbitrary distortion
  * Bloom
  * Glare
* Materials
  * Metal
  * Transmissive with roughness
  * Mix
  * Layer
* Volumetric
* Spectral
* Lights
  * Experiment with sampling triangle via solid angle after selecting it via area
  * Experiment with unifying sampling mesh lights and environment map
  * Build sampling data structures on GPU
* Testing
  * Proper statistical tests GPU sampling routines
  * Proper statistical tests to make sure images have expected mean/variance
  * Should ensure validation layers are clean during tests
* Resource management
  * Make sure we have all necessary `errdefers`
  * Delayed-destruction resources should be attached to command buffer
  * GPU resource arrays should be resizable
  * Need some sort of way to do async resource creation (transfers, processing)
* Use physical (with correct scales) units
* Integrators
  * ReSTIR DI
  * ReSTIR PT

### Some notes about conventions
* `+z` is up
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
