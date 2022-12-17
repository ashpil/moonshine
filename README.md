# My general purpose ray traced renderer

Built with Zig + Vulkan ray tracing.

### Subprojects
* offline -- a headless offline renderer
* rtchess -- intended to be a ray traced chess game, sort of in disrepair at the moment

### Build dependencies:
* `zig`
* `dxc`
* For Linux (Ubuntu, similar on others):
    * For Wayland: `wayland-protocols` `libwayland-dev` `libxkbcommon-dev`
    * For X11: `libxcursor-dev` `libxrandr-dev` `libxinerama-dev` `libxi-dev`

### // TODO
* Feature
  * Interactive viewer
  * Proper generic material system
    * How to do this on GPU???
  * Bloom
  * Tonemapping
  * HDR display
  * Figure out proper way to do whole shader binding thing -- how to avoid globals?
  * More camera models
    * Orthographic
  * Add dev interface:
    * UI vs CLI?
      * UI prettier, better for demos
      * UI better learning curve 
      * CLI easier to get set up
      * Probably do CLI first then UI after if still want
    * Set:
      * certain debug modes
      * whether certain path tracing techniques are used
      * Scene
      * Background
      * Samples per pixel, light samples, etc
      * Camera settings (ortho vs persp)
      * Max samples
    * Display:
      * Perf stuff
      * Current camera settings
      * Current scene info
    * Commands:
      * Refresh frame count
* Code
  * Make sure we have all necessary `errdefer`s
  * Proper memory allocation interface
  * Reduce unnecessary copying
  * Build alias table or alternative on GPU?

### Some notes about conventions, as idk where else to put them:
* `+y` is up
* phi is azimuthal angle (0-2pi) and theta is polar angle (0-pi)

## Some light reading
- [Importance sampling](https://computergraphics.stackexchange.com/q/4979)
- [Explicit light sampling](https://computergraphics.stackexchange.com/q/5152)
- [Multiple importance sampling](https://graphics.stanford.edu/courses/cs348b-03/papers/veach-chapter9.pdf)
- [Microfacets](https://agraphicsguy.wordpress.com/2015/11/01/sampling-microfacet-brdf/)
- [Actual materials](https://github.com/wdas/brdf) - ton of BRDF examples, in **CODE**!
- [Better sky](https://sebh.github.io/publications/egsr2020.pdf)
