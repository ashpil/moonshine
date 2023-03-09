# Core engine

### Systems
Each "system" is a relatively self-contained... system that is designed to do a specific thing.
Systems require certain instance/device functions to be enabled in order to use them, so they export them from their root file.

#### Current systems
* `rendersystem` - general ray traced rendering tasks, more monolithic than it should be currently
* `displaysystem` - platform-agnostic abstraction for rendering images and managing e.g., swapchain, double-buffering, presentation, etc

