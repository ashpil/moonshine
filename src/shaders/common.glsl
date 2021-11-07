const float PI = 3.14159265;
const float EPSILON = 0.000000119;

struct Payload {
    bool done;

    uint materialIndex;
    int index;

    vec3 point;
    vec3 normal;
    vec2 texcoord;
};
