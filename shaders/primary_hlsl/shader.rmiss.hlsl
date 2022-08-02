#include "payload.hlsl"

[shader("miss")]
void main(inout Payload payload) {
    payload.done = true;
}