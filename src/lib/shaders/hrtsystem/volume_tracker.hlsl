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

struct VolumeTracker {
    static const uint VOLUME_PRIORITY_COUNT = 8;

    Volume current[VOLUME_PRIORITY_COUNT];
    int depth[VOLUME_PRIORITY_COUNT - 1]; // last is always global, which is known to have depth == 0

    Volume other;
    bool inside;
    uint priority;

    // find volume stack containing the world-space position. expensive
    static VolumeTracker fromPosition(Scene scene, float3 position, float λ) {
        VolumeTracker t;
        for (uint i = 0; i < VOLUME_PRIORITY_COUNT - 1; i++) {
            t.depth[i] = 0;
            t.current[i + 1] = scene.globalVolume.at(λ);
        }
        t.current[0] = scene.globalVolume.at(λ);
        t.inside = true; // should be unused
        t.priority = 0;

        Ray ray = { position, float3(0, 1, 0) }; // direction arbitrary
        for (Intersection its = Intersection::find(scene.tlas, ray, 1.#INF, ~Instance::THIN_MASK); its.hit(); its = Intersection::find(scene.tlas, ray, 1.#INF, ~Instance::THIN_MASK)) {
            const SurfacePoint surface = scene.world.surfacePoint(its.instanceIndex, its.geometryIndex, its.primitiveIndex, its.barycentrics);
            const Volume volume = scene.world.material(its.instanceIndex, its.geometryIndex).volume.at(λ);
            const uint priority = scene.world.priority(its.instanceIndex);

            const bool entering = dot(ray.direction, surface.triangleFrame.n) < 0;
            if (entering) {
                // make sure we don't get something *slightly* above zero when we should've had zero
                // the more principled thing here is probably some ULP shenanigans
                t.current[priority] = VolumeAlgebra::sub(t.current[priority], VolumeAlgebra::add(volume, Volume::create(Homogeneous::create(volume.medium.σ_s * 0.0000001, volume.medium.σ_a * 0.0000001), 1)));
                t.depth[priority - 1] -= 1;
            } else {
                t.current[priority] = VolumeAlgebra::add(t.current[priority], volume);
                t.depth[priority - 1] += 1;
            }
            ray.origin = surface.position + faceForward(surface.triangleFrame.n, ray.direction) * surface.spawnOffset;
        }

        for (uint i = 0; i < VOLUME_PRIORITY_COUNT; i++) {
            t.current[i] = t.current[i];
        }
        t.other = t.current[t.activePriority()];
        return t;
    }

    // surface should only be considered if this returns true
    bool newBoundary(bool newInside, uint newPriority, Volume newVolume) {
        inside = newInside;
        priority = newPriority;
        if (inside) {
            if (depth[priority - 1] > 1) {
                other = VolumeAlgebra::sub(current[priority], newVolume);
            } else {
                other = current[0];
                for (uint i = priority - 1; i > 0; i--) {
                    if (depth[i - 1] != 0) {
                        other = current[i];
                        break;
                    }
                }
            }
        } else {
            if (depth[priority - 1] > 0) {
                other = VolumeAlgebra::add(current[priority], newVolume);
            } else {
                other = newVolume;
            }
        }
        return activePriority() <= priority;
    }

    bool isIndexMatched() {
        return currentVolume().IOR == other.IOR;
    }

    Volume currentVolume() {
        // assume that negative numbers here are due to bad roundoff, and clamp
        return VolumeAlgebra::clampToValid(current[activePriority()]);
    }

    uint activePriority() {
        for (uint i = VOLUME_PRIORITY_COUNT - 1; i > 0; i--) {
            if (depth[i - 1] != 0) return i;
        }
        return 0;
    }

    Volume internal() {
        if (inside) {
            return currentVolume();
        } else {
            return VolumeAlgebra::clampToValid(other);
        }
    }

    Volume external() {
        if (inside) {
            return VolumeAlgebra::clampToValid(other);
        } else {
            return currentVolume();
        }
    }

    void cross() {
        current[priority] = other;
        depth[priority - 1] += inside ? -1 : 1;
    }
};