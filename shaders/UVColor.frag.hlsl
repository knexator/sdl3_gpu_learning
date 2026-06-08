float4 main( float2 Texcoord : TEXCOORD0, float4 Color : TEXCOORD1) : SV_Target0
{
    return Color * float4(Texcoord, 1, 1);
}
