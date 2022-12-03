#include "intersection.hlsl"

[shader("miss")]
void main(inout Intersection its) {
    its = Intersection::createMiss();
}

