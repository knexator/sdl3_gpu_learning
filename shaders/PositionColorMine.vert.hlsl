struct ThingData
{
    float2 PositionOffset;
};

struct Input
{
    float3 Position : TEXCOORD0;
    float4 Color : TEXCOORD1;
};

struct Output
{
    float4 Color : TEXCOORD0;
    float4 Position : SV_Position;
};

StructuredBuffer<ThingData> DataBuffer : register(t0, space0);

Output main(Input input, uint id : SV_InstanceID)
{
    Output output;
    output.Color = input.Color;
    output.Position = float4(input.Position + float3(DataBuffer[id].PositionOffset, 0), 1.0f);
    return output;
}
