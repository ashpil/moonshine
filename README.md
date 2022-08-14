# Chess with ray tracing - please think of a better name

### Build dependencies:
* Zig
* dxc on your path

### Possible optimizations
* Better memory/buffers
* Create homebrew version of `std.MultiArrayList` that has len as a `u32`, as that's what a `DeviceSize` is

### Random thoughts
* Orthographic projection might look visually interesting in this context 

### // TODO
* Make sure we have all necessary `errdefer`s
* Proper asset system - load scene from file rather than hardcoded
* Swap off of GLFW?
* Offline image generator -- would be healthy two have two consumers of engine library code
* Add dev interface:
  * UI vs CLI?
    * UI prettier, better for demos
    * UI better learning curve 
    * CLI easier to get set up
    * Probably do CLI first then UI after if still want
  * Set:
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

## Some light reading
- [Importance sampling](https://computergraphics.stackexchange.com/q/4979)
- [Explicit light sampling](https://computergraphics.stackexchange.com/q/5152)
- [Multiple importance sampling](https://graphics.stanford.edu/courses/cs348b-03/papers/veach-chapter9.pdf)
- [Microfacets](https://agraphicsguy.wordpress.com/2015/11/01/sampling-microfacet-brdf/)
- [Actual materials](https://github.com/wdas/brdf) - ton of BRDF examples, in **CODE**!
- [Better sky](https://sebh.github.io/publications/egsr2020.pdf)
