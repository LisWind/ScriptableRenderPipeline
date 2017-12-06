#ifndef UNITY_COMMON_MATERIAL_INCLUDED
#define UNITY_COMMON_MATERIAL_INCLUDED

//-----------------------------------------------------------------------------
// Helper functions for roughness
//-----------------------------------------------------------------------------

float PerceptualRoughnessToRoughness(float perceptualRoughness)
{
    return perceptualRoughness * perceptualRoughness;
}

float RoughnessToPerceptualRoughness(float roughness)
{
    return sqrt(roughness);
}

float PerceptualSmoothnessToRoughness(float perceptualSmoothness)
{
    return (1.0 - perceptualSmoothness) * (1.0 - perceptualSmoothness);
}

float PerceptualSmoothnessToPerceptualRoughness(float perceptualSmoothness)
{
    return (1.0 - perceptualSmoothness);
}

// Using roughness values of 0 leads to INFs and NANs. The only sensible place to use the roughness
// value of 0 is IBL, so we do not modify the perceptual roughness which is used to select the MIP map level.
// Note: making the constant too small results in aliasing.
float ClampRoughnessForAnalyticalLights(float roughness)
{
    return max(roughness, 1.0/1024.0);
}

// 'bsdfData.roughnessT' and 'bsdfData.roughnessB' are clamped, and are meant to be used with analytical lights.
// 'bsdfData.perceptualRoughness' is not clamped, and is meant to be used for IBL.
// If IBL needs the linear roughness value for some reason, it can be computed as follows:
// float roughness = PerceptualRoughnessToRoughness(bsdfData.perceptualRoughness);
void ConvertAnisotropyToRoughness(float perceptualRoughness, float anisotropy, out float roughnessT, out float roughnessB)
{
    float roughness = PerceptualRoughnessToRoughness(perceptualRoughness);

    // Use the parametrization of Sony Imageworks.
    // Ref: Revisiting Physically Based Shading at Imageworks, p. 15.
    roughnessT = roughness * (1 + anisotropy);
    roughnessB = roughness * (1 - anisotropy);

    roughnessT = ClampRoughnessForAnalyticalLights(roughnessT);
    roughnessB = ClampRoughnessForAnalyticalLights(roughnessB);
}

// ----------------------------------------------------------------------------
// Parallax mapping
// ----------------------------------------------------------------------------

// ref https://www.gamedev.net/topic/678043-how-to-blend-world-space-normals/#entry5287707
// assume compositing in world space
// Note: Using vtxNormal = float3(0, 0, 1) give the BlendNormalRNM formulation.
// TODO: Untested
float3 BlendNormalWorldspaceRNM(float3 n1, float3 n2, float3 vtxNormal)
{
    // Build the shortest-arc quaternion
    float4 q = float4(cross(vtxNormal, n2), dot(vtxNormal, n2) + 1.0) / sqrt(2.0 * (dot(vtxNormal, n2) + 1));

    // Rotate the normal
    return n1 * (q.w * q.w - dot(q.xyz, q.xyz)) + 2 * q.xyz * dot(q.xyz, n1) + 2 * q.w * cross(q.xyz, n1);
}

// ref http://blog.selfshadow.com/publications/blending-in-detail/
// ref https://gist.github.com/selfshadow/8048308
// Reoriented Normal Mapping
// Blending when n1 and n2 are already 'unpacked' and normalised
// assume compositing in tangent space
float3 BlendNormalRNM(float3 n1, float3 n2)
{
    float3 t = n1.xyz + float3(0.0, 0.0, 1.0);
    float3 u = n2.xyz * float3(-1.0, -1.0, 1.0);
    float3 r = (t / t.z) * dot(t, u) - u;
    return r;
}

// assume compositing in tangent space
float3 BlendNormal(float3 n1, float3 n2)
{
    return normalize(float3(n1.xy * n2.z + n2.xy * n1.z, n1.z * n2.z));
}

// Ref: http://http.developer.nvidia.com/GPUGems3/gpugems3_ch01.html / http://www.slideshare.net/icastano/cascades-demo-secrets
float3 ComputeTriplanarWeights(float3 normal)
{
    // Determine the blend weights for the 3 planar projections.
    float3 blendWeights = abs(normal);
    // Tighten up the blending zone
    blendWeights = (blendWeights - 0.2) * 7.0;
    blendWeights = blendWeights * blendWeights * blendWeights; // pow(blendWeights, 3);
    // Force weights to sum to 1.0 (very important!)
    blendWeights = max(blendWeights, float3(0.0, 0.0, 0.0));
    blendWeights /= dot(blendWeights, 1.0);

    return blendWeights;
}

// Planar/Triplanar convention for Unity in world space
void GetTriplanarCoordinate(float3 position, out float2 uvXZ, out float2 uvXY, out float2 uvZY)
{
    // Caution: This must follow the same rule as what is use for SurfaceGradient triplanar
    // TODO: Currently the normal mapping looks wrong without SURFACE_GRADIENT option because we don't handle corretly the tangent space
    uvXZ = float2(position.z, position.x);
    uvXY = float2(position.x, position.y);
    uvZY = float2(position.z, position.y);
}

float LerpWhiteTo(float b, float t)
{
    float oneMinusT = 1.0 - t;
    return oneMinusT + b * t;
}

float3 LerpWhiteTo(float3 b, float t)
{
    float oneMinusT = 1.0 - t;
    return float3(oneMinusT, oneMinusT, oneMinusT) + b * t;
}

// ----------------------------------------------------------------------------
// SSS/Transmittance
// ----------------------------------------------------------------------------

// Computes the fraction of light passing through the object.
// Evaluate Int{0, inf}{2 * Pi * r * R(sqrt(r^2 + d^2))}, where R is the diffusion profile.
// Note: 'volumeAlbedo' should be premultiplied by 0.25.
// Ref: Approximate Reflectance Profiles for Efficient Subsurface Scattering by Pixar (BSSRDF only).
float3 ComputeTransmittanceDisney(float3 S, float3 volumeAlbedo, float thickness, float radiusScale)
{
    // Thickness and SSS radius are decoupled for artists.
    // In theory, we should modify the thickness by the inverse of the radius scale of the profile.
    // thickness /= radiusScale;

#if 0
    float3 expOneThird = exp(((-1.0 / 3.0) * thickness) * S);
#else
    // Help the compiler.
    float  k = (-1.0 / 3.0) * LOG2_E;
    float3 p = (k * thickness) * S;
    float3 expOneThird = exp2(p);
#endif

    // Premultiply & optimize: T = (1/4 * A) * (e^(-t * S) + 3 * e^(-1/3 * t * S))
    return volumeAlbedo * (expOneThird * expOneThird * expOneThird + 3 * expOneThird);
}

// Evaluates transmittance for a linear combination of two normalized 2D Gaussians.
// Ref: Real-Time Realistic Skin Translucency (2010), equation 9 (modified).
// Note: 'volumeAlbedo' should be premultiplied by 0.25, correspondingly 'lerpWeight' by 4,
// and 'halfRcpVariance1' should be prescaled by (0.1 * SssConstants.SSS_BASIC_DISTANCE_SCALE)^2.
float3 ComputeTransmittanceJimenez(float3 halfRcpVariance1, float lerpWeight1,
                                   float3 halfRcpVariance2, float lerpWeight2,
                                   float3 volumeAlbedo, float thickness, float radiusScale)
{
    // Thickness and SSS radius are decoupled for artists.
    // In theory, we should modify the thickness by the inverse of the radius scale of the profile.
    // thickness /= radiusScale;

    float t2 = thickness * thickness;

    // T = A * lerp(exp(-t2 * halfRcpVariance1), exp(-t2 * halfRcpVariance2), lerpWeight2)
    return volumeAlbedo * (exp(-t2 * halfRcpVariance1) * lerpWeight1 + exp(-t2 * halfRcpVariance2) * lerpWeight2);
}

// Ref: Steve McAuley - Energy-Conserving Wrapped Diffuse
float ComputeWrappedDiffuseLighting(float NdotL, float w)
{
    return saturate((NdotL + w) / ((1 + w) * (1 + w)));
}

// In order to support subsurface scattering, we need to know which pixels have an SSS material.
// It can be accomplished by reading the stencil buffer.
// A faster solution (which avoids an extra texture fetch) is to simply make sure that
// all pixels which belong to an SSS material are not black (those that don't always are).
// We choose the blue color channel since it's perceptually the least noticeable.
float3 TagLightingForSSS(float3 subsurfaceLighting)
{
    subsurfaceLighting.b = max(subsurfaceLighting.b, HALF_MIN);
    return subsurfaceLighting;
}

// See TagLightingForSSS() for details.
bool TestLightingForSSS(float3 subsurfaceLighting)
{
    return subsurfaceLighting.b > 0;
}


#endif // UNITY_COMMON_MATERIAL_INCLUDED
