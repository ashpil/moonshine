[[vk::binding(0, 0)]] RWStructuredBuffer<float> levels;

struct PushConsts {
    uint srcLevelOffset;
    uint dstLevelOffset;
    uint maxSrcIndex;
};
[[vk::push_constant]] PushConsts pushConsts;

[numthreads(32, 1, 1)]
void main(uint3 dispatchXYZ: SV_DispatchThreadID) {
    const uint dstIndex = dispatchXYZ.x;
    const uint dstLevelSize = pushConsts.srcLevelOffset - pushConsts.dstLevelOffset;

    if (any(dstIndex >= dstLevelSize)) return;

    const uint srcBaseIndex = 2 * dstIndex;

    if (srcBaseIndex < pushConsts.maxSrcIndex) {
        levels[pushConsts.dstLevelOffset + dstIndex] = levels[pushConsts.srcLevelOffset + srcBaseIndex + 0]
                                                     + levels[pushConsts.srcLevelOffset + srcBaseIndex + 1];
    } else {
        levels[pushConsts.dstLevelOffset + dstIndex] = 0;
    }
}