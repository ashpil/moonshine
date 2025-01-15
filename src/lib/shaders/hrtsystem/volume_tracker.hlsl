#include "volume.hlsl"

Volume volumeAdd(Volume lhs, Volume rhs) {
    Volume o;
    o.medium.σ_s = lhs.medium.σ_s + rhs.medium.σ_s;
    o.medium.σ_a = lhs.medium.σ_a + rhs.medium.σ_a;
    o.IOR = lhs.IOR * rhs.IOR;
    return o;
}

Volume volumeSub(Volume lhs, Volume rhs) {
    Volume o;
    // not fully a group as there's no valid inverse for these
    // assume that negative numbers here are due to bad roundoff, and clamp to 0
    o.medium.σ_s = max(lhs.medium.σ_s - rhs.medium.σ_s, 0);
    o.medium.σ_a = max(lhs.medium.σ_a - rhs.medium.σ_a, 0);
    o.IOR = lhs.IOR / rhs.IOR;
    return o;
}

struct VolumeBoundary {
    Volume internal;
    Volume external;

    static VolumeBoundary none(Volume v) {
        VolumeBoundary b;
        b.internal = v;
        b.external = v;
        return b;
    }

    bool isIndexMatched() {
        return internal.IOR == external.IOR;
    }
};

struct VolumeTracker {
    Volume current;

    static VolumeTracker create(Volume initial) {
        VolumeTracker t;
        t.current = initial;
        return t;
    }

    VolumeBoundary boundary(bool inside, Volume v) {
        VolumeBoundary boundary;
        if (inside) {
            boundary.internal = current;
            boundary.external = volumeSub(current, v);
        } else {
            boundary.internal = volumeAdd(current, v);
            boundary.external = current;
        }
        return boundary;
    }

    void cross(bool entering, VolumeBoundary boundary) {
        if (entering) {
            current = boundary.internal;
        } else {
            current = boundary.external;
        }
    }
};