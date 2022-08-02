static const float PI = 3.14159265;
static const float EPSILON = 0.000000119;

struct [raypayload] Payload {
    bool done : read(caller) : write(closesthit, miss);

    uint materialIndex : read(caller) : write(closesthit, miss);
    int index : read(caller) : write(closesthit, miss);

    float3 position : read(caller) : write(closesthit, miss);
    float3 normal : read(caller) : write(closesthit, miss);
    float2 texcoord : read(caller) : write(closesthit, miss);
};
