struct Input
{
    float2 Position : TEXCOORD0;
    float2 TexCoord : TEXCOORD1;
    float4 Color : TEXCOORD2;
    uint TextureId : TEXCOORD3;
};

struct Output
{
    float4 Position : SV_Position;
    float2 TexCoord : TEXCOORD0;
    float4 Color : TEXCOORD1;
    nointerpolation uint TextureId : TEXCOORD2;
};

Output main(Input input)
{
    Output output;
    output.TexCoord = input.TexCoord;
    output.Color = input.Color;
    output.Position = float4(input.Position, 0.0f, 1.0f);
    // output.TextureId = 1;
    output.TextureId = input.TextureId;
    return output;
}