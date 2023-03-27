# Core engine

### Systems
Each "system" is a relatively self-contained... system that is designed to do a specific thing.
Systems require certain instance/device functions to be enabled in order to use them, so they export them from their root file.

#### Current systems
* `core` - basic things like context, allocation, commonly used utilities, etc
* `rendersystem` - general hardware-RT ray traced rendering tasks and scene representation
* `displaysystem` - platform-agnostic abstraction for rendering images and managing e.g., swapchain, double-buffering, presentation, etc
