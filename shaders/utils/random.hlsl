#pragma once

#include "math.hlsl"

// https://www.reedbeta.com/blog/hash-functions-for-gpu-rendering/
// https://jcgt.org/published/0009/03/02/
namespace Hash {
    uint lcg(uint a) {
        const uint multiplier = 747796405u;
        const uint increment = 2891336453u;
        return a * multiplier + increment;
    }

    // RXS-M-XS PCG permutation function
    uint rxs_m_xs(uint a) {
        const uint b = ((a >> ((a >> 28u) + 4u)) ^ a) * 277803737u;
        return (b >> 22u) ^ b;
    }

    uint pcg(uint a) {
        return rxs_m_xs(lcg(a));
    }
}

struct Rng {
    uint state;

    static Rng fromSeed(uint3 seed) {
        Rng rng;
        rng.state = Hash::pcg(seed.x + Hash::pcg(seed.y + Hash::pcg(seed.z)));
        return rng;
    }

    void stepState() {
        state = Hash::lcg(state);
    }

    float getFloat() {
        stepState();

        uint hashed_uint = Hash::rxs_m_xs(state);

        // convert to float [0-1)
        // https://pharr.org/matt/blog/2022/03/05/sampling-fp-unit-interval
        return float(hashed_uint >> 8) * 0x1p-24f;
    }
};
