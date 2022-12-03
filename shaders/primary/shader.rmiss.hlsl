#include "payload.hlsl"
#include "math.hlsl"

[shader("miss")]
void main(inout Payload payload) {
    payload.instanceID = MAX_UINT;
}

