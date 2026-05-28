using Godot;
using System;

namespace Godotwind.Native;

/// <summary>
/// Builds a curved river surface mesh from generic Godot-space curve data.
/// Source adapters own where the curve came from; this class only turns a
/// path, widths, and subdivision settings into renderable water geometry.
/// </summary>
[GlobalClass]
public partial class NativeRiverMeshBuilder : RefCounted
{
    public Godot.Collections.Dictionary BuildCurveRiverMesh(
        Curve3D curve,
        Godot.Collections.Array<float> pointWidths,
        int lengthDivisions,
        int widthDivisions,
        float tangentSmoothness)
    {
        if (curve == null || curve.PointCount < 2)
            return ErrorResult("curve must contain at least two points");

        int crossDivs = Math.Max(1, widthDivisions);
        int alongDivs = Math.Max(1, lengthDivisions);
        float length = Math.Max(0.001f, curve.GetBakedLength());
        float stepLength = length / alongDivs;
        float smooth = Math.Max(0.05f, tangentSmoothness) * stepLength;

        var widths = NormalizeWidths(curve.PointCount, pointWidths);
        var rows = alongDivs + 1;
        var columns = crossDivs + 1;
        var vertices = new Vector3[rows * columns];
        var normals = new Vector3[rows * columns];
        var tangents = new float[rows * columns * 4];
        var uvs = new Vector2[rows * columns];
        var uv2s = new Vector2[rows * columns];
        var colors = new Color[rows * columns];
        var indices = new int[alongDivs * crossDivs * 6];
        var bounds = new Aabb();
        bool boundsStarted = false;
        var rowCenters = new Vector3[rows];
        var rowDistances = new float[rows];
        var rowTangents = new Vector3[rows];

        for (int row = 0; row < rows; row++)
        {
            float distance = Math.Min(length, row * stepLength);
            rowDistances[row] = distance;
            rowCenters[row] = curve.SampleBaked(distance, true);
            rowTangents[row] = SampleCurveTangent(curve, rowCenters[row], distance, length, smooth, stepLength);
            if (row > 0 && rowTangents[row].Dot(rowTangents[row - 1]) < 0.0f)
                rowTangents[row] = -rowTangents[row];
        }

        rowTangents = SmoothTangentField(rowTangents, tangentSmoothness);

        for (int row = 0; row < rows; row++)
        {
            float alongT = row / (float)alongDivs;
            float distance = rowDistances[row];
            Vector3 center = rowCenters[row];
            Vector3 tangent = rowTangents[row];
            Vector3 prevTangent = row > 0 ? rowTangents[row - 1] : tangent;
            Vector3 nextTangent = row + 1 < rows ? rowTangents[row + 1] : tangent;
            float width = WidthAt(widths, alongT);
            float baseHalfWidth = Math.Max(0.05f, width * 0.5f);
            float halfWidth = baseHalfWidth * CurvatureWidthScale(prevTangent, nextTangent, baseHalfWidth, Math.Max(stepLength, smooth * 2.0f));
            Vector3 right = BuildMiterRight(prevTangent, tangent, nextTangent, halfWidth, stepLength);
            Vector3 tangentRight = right.Normalized();
            var flow2 = new Vector2(tangent.X, tangent.Z);
            if (flow2.LengthSquared() < 0.0001f)
                flow2 = Vector2.Up;
            flow2 = flow2.Normalized();

            for (int col = 0; col < columns; col++)
            {
                float acrossT = col / (float)crossDivs;
                float signedAcross = acrossT * 2.0f - 1.0f;
                Vector3 vertex = center - right * signedAcross * halfWidth;
                int index = row * columns + col;
                float bankDistance = 1.0f - MathF.Abs(signedAcross);
                float foam = 1.0f - SmoothStep(0.0f, 0.32f, bankDistance);

                vertices[index] = vertex;
                normals[index] = Vector3.Up;
                int tangentIndex = index * 4;
                tangents[tangentIndex] = tangentRight.X;
                tangents[tangentIndex + 1] = tangentRight.Y;
                tangents[tangentIndex + 2] = tangentRight.Z;
                tangents[tangentIndex + 3] = 1.0f;
                uvs[index] = new Vector2(acrossT, distance);
                uv2s[index] = new Vector2(alongT, bankDistance);
                colors[index] = new Color(
                    EncodeSignedUnit(flow2.X),
                    EncodeSignedUnit(flow2.Y),
                    bankDistance,
                    foam
                );

                if (!boundsStarted)
                {
                    bounds = new Aabb(vertex, Vector3.Zero);
                    boundsStarted = true;
                }
                else
                {
                    bounds = bounds.Expand(vertex);
                }
            }
        }

        int write = 0;
        for (int row = 0; row < alongDivs; row++)
        {
            for (int col = 0; col < crossDivs; col++)
            {
                int a = row * columns + col;
                int b = a + 1;
                int c = (row + 1) * columns + col;
                int d = c + 1;
                indices[write++] = a;
                indices[write++] = b;
                indices[write++] = c;
                indices[write++] = b;
                indices[write++] = d;
                indices[write++] = c;
            }
        }

        var arrays = new Godot.Collections.Array();
        arrays.Resize((int)Mesh.ArrayType.Max);
        arrays[(int)Mesh.ArrayType.Vertex] = vertices;
        arrays[(int)Mesh.ArrayType.Normal] = normals;
        arrays[(int)Mesh.ArrayType.Tangent] = tangents;
        arrays[(int)Mesh.ArrayType.TexUV] = uvs;
        arrays[(int)Mesh.ArrayType.TexUV2] = uv2s;
        arrays[(int)Mesh.ArrayType.Color] = colors;
        arrays[(int)Mesh.ArrayType.Index] = indices;

        var mesh = new ArrayMesh();
        mesh.AddSurfaceFromArrays(Mesh.PrimitiveType.Triangles, arrays);
        mesh.ResourceLocalToScene = true;

        return new Godot.Collections.Dictionary
        {
            ["mesh"] = mesh,
            ["bounds"] = bounds,
            ["length"] = length,
            ["vertex_count"] = vertices.Length,
            ["triangle_count"] = indices.Length / 3,
            ["error"] = "",
        };
    }

    private static Godot.Collections.Dictionary ErrorResult(string error)
    {
        return new Godot.Collections.Dictionary
        {
            ["mesh"] = default(Variant),
            ["bounds"] = new Aabb(),
            ["length"] = 0.0f,
            ["vertex_count"] = 0,
            ["triangle_count"] = 0,
            ["error"] = error,
        };
    }

    private static float[] NormalizeWidths(int pointCount, Godot.Collections.Array<float> pointWidths)
    {
        var result = new float[Math.Max(2, pointCount)];
        for (int i = 0; i < result.Length; i++)
        {
            float width = 8.0f;
            if (pointWidths != null && i < pointWidths.Count)
                width = pointWidths[i];
            else if (pointWidths != null && pointWidths.Count > 0)
                width = pointWidths[pointWidths.Count - 1];
            result[i] = Math.Max(0.1f, width);
        }
        return result;
    }

    private static float WidthAt(float[] widths, float t)
    {
        if (widths.Length == 1)
            return widths[0];
        float scaled = Math.Clamp(t, 0.0f, 1.0f) * (widths.Length - 1);
        int index = Math.Min(widths.Length - 2, (int)MathF.Floor(scaled));
        float localT = scaled - index;
        return Mathf.Lerp(widths[index], widths[index + 1], localT);
    }

    private static float EncodeSignedUnit(float value)
    {
        return Math.Clamp(value * 0.5f + 0.5f, 0.0f, 1.0f);
    }

    private static Vector3 SampleCurveTangent(Curve3D curve, Vector3 center, float distance, float length, float smooth, float stepLength)
    {
        Vector3 backward = curve.SampleBaked(Math.Clamp(distance - smooth, 0.0f, length), true);
        Vector3 forward = curve.SampleBaked(Math.Clamp(distance + smooth, 0.0f, length), true);
        Vector3 tangent = forward - backward;
        if (tangent.LengthSquared() < 0.0001f)
            tangent = curve.SampleBaked(Math.Min(length, distance + stepLength), true) - center;
        if (tangent.LengthSquared() < 0.0001f)
            tangent = center - curve.SampleBaked(Math.Max(0.0f, distance - stepLength), true);
        if (tangent.LengthSquared() < 0.0001f)
            tangent = Vector3.Forward;
        return tangent.Normalized();
    }

    private static Vector3[] SmoothTangentField(Vector3[] tangents, float tangentSmoothness)
    {
        if (tangents.Length <= 2)
            return tangents;

        int radius = Math.Clamp((int)MathF.Ceiling(tangentSmoothness * 1.5f), 1, 6);
        var smoothed = new Vector3[tangents.Length];
        for (int i = 0; i < tangents.Length; i++)
        {
            Vector3 center = tangents[i];
            Vector3 sum = center * (radius + 1);
            float totalWeight = radius + 1;
            for (int offset = -radius; offset <= radius; offset++)
            {
                if (offset == 0)
                    continue;
                int j = Math.Clamp(i + offset, 0, tangents.Length - 1);
                float weight = radius + 1 - Math.Abs(offset);
                Vector3 neighbor = tangents[j];
                if (neighbor.Dot(center) < 0.0f)
                    neighbor = -neighbor;
                sum += neighbor * weight;
                totalWeight += weight;
            }
            smoothed[i] = sum.LengthSquared() < 0.0001f ? center : (sum / totalWeight).Normalized();
        }
        return smoothed;
    }

    private static Vector3 BuildMiterRight(Vector3 prevTangent, Vector3 tangent, Vector3 nextTangent, float halfWidth, float rowStep)
    {
        Vector3 prevRight = SafeRight(prevTangent);
        Vector3 currRight = SafeRight(tangent);
        Vector3 nextRight = SafeRight(nextTangent);
        Vector3 miter = prevRight + nextRight;
        if (miter.LengthSquared() < 0.0001f)
            return currRight;
        miter = miter.Normalized();
        float denom = MathF.Abs(miter.Dot(currRight));
        if (denom < 0.55f)
            return currRight;
        float maxScaleFromStep = Math.Max(1.0f, (rowStep * 0.72f) / Math.Max(halfWidth, 0.001f));
        float miterScale = Math.Min(Math.Min(1.0f / denom, 1.25f), maxScaleFromStep);
        return miter * miterScale;
    }

    private static Vector3 SafeRight(Vector3 tangent)
    {
        Vector3 right = tangent.Cross(Vector3.Up);
        if (right.LengthSquared() < 0.0001f)
            right = Vector3.Right;
        return right.Normalized();
    }

    private static float CurvatureWidthScale(Vector3 prevTangent, Vector3 nextTangent, float halfWidth, float sampleSpan)
    {
        float dot = Math.Clamp(prevTangent.Dot(nextTangent), -1.0f, 1.0f);
        float turnAngle = MathF.Acos(dot);
        float scale = 1.0f;
        if (turnAngle <= 0.65f)
            return scale;
        scale = Math.Clamp(1.0f - (turnAngle - 0.65f) * 0.45f, 0.42f, 1.0f);
        float radius = sampleSpan / Math.Max(turnAngle, 0.001f);
        float maxHalfWidth = Math.Max(0.35f, radius * 0.55f);
        if (halfWidth > maxHalfWidth)
            scale = Math.Min(scale, maxHalfWidth / halfWidth);
        return Math.Clamp(scale, 0.22f, 1.0f);
    }

    private static float SmoothStep(float edge0, float edge1, float x)
    {
        float t = Math.Clamp((x - edge0) / Math.Max(0.0001f, edge1 - edge0), 0.0f, 1.0f);
        return t * t * (3.0f - 2.0f * t);
    }
}
