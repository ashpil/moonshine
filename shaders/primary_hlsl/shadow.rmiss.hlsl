struct [raypayload] ShadowPayload {
    bool inShadow : read(caller) : write(miss);
};

[shader("miss")]
void main(inout ShadowPayload payload) {
    payload.inShadow = false;
}
