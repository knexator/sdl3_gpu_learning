// Texture2D<float4> Texture : register(t0, space2);
// SamplerState Sampler : register(s0, space2);

// TODO:
// nointerpolation uint Flags : TEXCOORD2;
// nointerpolation uint Material : TEXCOORD3;
// float2 TexCoord : TEXCOORD0

// why space2? because of http://wiki.libsdl.org/SDL3/SDL_CreateGPUShader
Texture2D<float4> Textures[3] : register(t0, space2);
SamplerState Sampler : register(s0, space2);

struct Input
{
    float2 TexCoord : TEXCOORD0;
    float4 Color : TEXCOORD1;
    nointerpolation uint TextureId : TEXCOORD2;
};

float4 sampleTexture(uint texture_id, float2 uv)
{
    switch (texture_id)
    {
        case 0:  return float4(1,1,1,1); // white for non-textures
        case 1:  return Textures[0].Sample(Sampler, uv);
        case 2:  return Textures[1].Sample(Sampler, uv);
        case 3:  return Textures[2].Sample(Sampler, uv);
        default: return float4(1, 0, 1, 1); // magenta = missing material
    }
}


float4 main(Input input) : SV_Target0
{
    return input.Color * sampleTexture(input.TextureId, input.TexCoord);
}
