struct VertexData
{
    float3 Position;
    float4 Color;
};

struct ThingData
{
    float2 PositionOffset;
};

struct Output
{
    float4 Color : TEXCOORD0;
    float4 Position : SV_Position;
};

StructuredBuffer<VertexData> VertexBuffer : register(t0, space0);
StructuredBuffer<ThingData> DataBuffer : register(t1, space0);

Output main(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID)
{
    Output output;
    output.Color = VertexBuffer[vertex_id].Color;
    output.Position = float4(VertexBuffer[vertex_id].Position + float3(DataBuffer[instance_id].PositionOffset, 0), 1.0f);
    return output;
}