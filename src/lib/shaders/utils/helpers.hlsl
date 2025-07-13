#pragma once

template<typename T>
uint2 textureDimensions(Texture2D<T> texture) {
    uint2 dimensions;
    texture.GetDimensions(dimensions.x, dimensions.y);
    return dimensions;
}

template<typename T>
uint2 textureDimensions(RWTexture2D<T> texture) {
    uint2 dimensions;
    texture.GetDimensions(dimensions.x, dimensions.y);
    return dimensions;
}

template<typename T>
uint textureDimensions(Texture1D<T> texture) {
    uint dimension;
    texture.GetDimensions(dimension);
    return dimension;
}

template<typename T>
uint textureDimensions(RWTexture1D<T> texture) {
    uint dimension;
    texture.GetDimensions(dimension);
    return dimension;
}

template<typename T>
uint bufferDimensions(StructuredBuffer<T> buffer) {
    uint size;
    uint stride;
    buffer.GetDimensions(size, stride);
    return size;
}

template<typename T>
uint bufferDimensions(RWStructuredBuffer<T> buffer) {
    uint size;
    uint stride;
    buffer.GetDimensions(size, stride);
    return size;
}
