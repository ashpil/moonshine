struct [raypayload] Payload {
    bool done : read(caller) : write(closesthit, miss);

    uint materialIndex : read(caller) : write(closesthit, miss);

    float3 position : read(caller) : write(closesthit, miss);
    float3 normal : read(caller) : write(closesthit, miss);
    float3 tangent : read(caller) : write(closesthit, miss);
    float2 texcoord : read(caller) : write(closesthit, miss);
};
