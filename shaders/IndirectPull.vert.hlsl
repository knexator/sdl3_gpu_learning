struct VertexData
{
    float3 Position;
    uint   Color;
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
    uint raw_color = VertexBuffer[vertex_id].Color;
    // this seems less efficient than a vertex attribute with SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM...
    output.Color = float4(
        ((raw_color >> 16) & 0xFF) / 255.0,   // R  ← bits 23..16
        ((raw_color >>  8) & 0xFF) / 255.0,   // G  ← bits 15..8
        ((raw_color >>  0) & 0xFF) / 255.0,   // B  ← bits  7..0
        ((raw_color >> 24) & 0xFF) / 255.0    // A  ← bits 31..24
    );
    output.Position = float4(VertexBuffer[vertex_id].Position.xy + DataBuffer[instance_id].PositionOffset, 0.0f, 1.0f);
    return output;
}