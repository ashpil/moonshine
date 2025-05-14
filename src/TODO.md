### // TODO
* Cameras
  * Fisheye
  * Lens System
* Materials
  * Conductor with complex IOR
  * Transmissive with roughness
  * Material composition
* Lights
  * Experiment with sampling triangle via solid angle after selecting it via area
  * Experiment with unifying sampling mesh lights and environment map
  * BVH
  * Sampling of filtered environment maps
* Testing
  * Proper statistical tests GPU sampling routines
  * Proper statistical tests to make sure images have expected mean/variance
* Resource management
  * Make sure we have all necessary `errdefers`
  * GPU resource arrays should be resizable
  * Need some sort of way to do async/parallel resource creation (transfers, processing)
* Use physical (with correct scales) units
* Integrators
  * ReSTIR
* Spectral EXR output
* Tonemapping
* HDR display
  * A satisfying implementation is blocked by [HDR display metadata querying in Vulkan](https://github.com/KhronosGroup/Vulkan-Docs/issues/1787)
* Make all objects scale-invariant
  * You should get the exact same image no matter what the root transform is, even if it is non-orthogonal
  * Cameras and backgrounds are currently missing this