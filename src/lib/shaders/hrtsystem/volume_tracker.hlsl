#include "volume.hlsl"

namespace VolumeAlgebra {
    Volume add(Volume lhs, Volume rhs) {
        Volume o;
        o.medium.σ_s = lhs.medium.σ_s + rhs.medium.σ_s;
        o.medium.σ_a = lhs.medium.σ_a + rhs.medium.σ_a;
        o.IOR = lhs.IOR * rhs.IOR;
        return o;
    }

    Volume sub(Volume lhs, Volume rhs) {
        Volume o;
        o.medium.σ_s = lhs.medium.σ_s - rhs.medium.σ_s;
        o.medium.σ_a = lhs.medium.σ_a - rhs.medium.σ_a;
        o.IOR = lhs.IOR / rhs.IOR;
        return o;
    }

    // not fully a group as there's no valid inverse for these
    Volume clampToValid(Volume v) {
        v.medium.σ_s = max(v.medium.σ_s, 0);
        v.medium.σ_a = max(v.medium.σ_a, 0);
        return v;
    }
};

// find volume containing the world-space position. expensive
static Volume findContainingVolume(Scene scene, float3 position, float λ) {
    Volume initial = scene.globalVolume.at(λ);
    Ray ray = { position, float3(0, 0, 1) }; // direction arbitrary
    for (Intersection its = Intersection::find(scene.tlas, ray, 1.#INF, 0b01111111); its.hit(); its = Intersection::find(scene.tlas, ray, 1.#INF, 0b01111111)) {
        const SurfacePoint surface = scene.world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);
        const Volume volume = scene.world.material(its.instanceIndex, its.geometryIndex).volume.at(λ);

        const bool entering = dot(ray.direction, surface.triangleFrame.n) < 0;
        if (entering) {
            // make sure we don't get something *slightly* above zero when we should've had zero
            // the more principled thing here is probably some ULP shenanigans
            initial = VolumeAlgebra::sub(initial, VolumeAlgebra::add(volume, Volume::create(Homogeneous::create(volume.medium.σ_s * 0.0000001, volume.medium.σ_a * 0.0000001), 1)));
        } else {
            initial = VolumeAlgebra::add(initial, volume);
        }
        ray.origin = surface.position + faceForward(surface.triangleFrame.n, ray.direction) * surface.spawnOffset;
    }
    return VolumeAlgebra::clampToValid(initial);
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
            // assume that negative numbers here are due to bad roundoff, and clamp
            boundary.external = VolumeAlgebra::clampToValid(VolumeAlgebra::sub(current, v));
        } else {
            boundary.internal = VolumeAlgebra::add(current, v);
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