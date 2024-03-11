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
uint bufferDimensions(StructuredBuffer<T> buffer) {
    uint size;
    uint stride;
    buffer.GetDimensions(size, stride);
    return size;
}