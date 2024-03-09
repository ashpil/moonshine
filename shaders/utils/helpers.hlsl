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