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
    for (Intersection its = Intersection::find(scene.tlas, ray, 1.#INF, ~Instance::THIN_MASK); its.hit(); its = Intersection::find(scene.tlas, ray, 1.#INF, ~Instance::THIN_MASK)) {
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

struct VolumeTracker {
    Volume current;

    Volume other;
    bool inside;

    static VolumeTracker create(Volume initial) {
        VolumeTracker t;
        t.current = initial;
        t.other = initial;
        t.inside = true; // should be unused
        return t;
    }

    void newBoundary(bool newInside, Volume newVolume) {
        inside = newInside;
        if (inside) {
            // assume that negative numbers here are due to bad roundoff, and clamp
            other = VolumeAlgebra::clampToValid(VolumeAlgebra::sub(current, newVolume));
        } else {
            other = VolumeAlgebra::add(current, newVolume);
        }
    }

    bool isIndexMatched() {
        return current.IOR == other.IOR;
    }

    Volume internal() {
        if (inside) {
            return current;
        } else {
            return other;
        }
    }

    Volume external() {
        if (inside) {
            return other;
        } else {
            return current;
        }
    }

    void cross() {
        current = other;
    }
};