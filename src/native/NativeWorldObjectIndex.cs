using Godot;
using System;
using System.Collections.Generic;

namespace Godotwind.Native;

/// <summary>
/// Spatial index for generic world-object records. It stores only stable IDs,
/// positions, cells, and capability flags; game-specific record decoding stays
/// in the GDScript adapter that feeds it.
/// </summary>
[GlobalClass]
public partial class NativeWorldObjectIndex : RefCounted
{
    private struct Entry
    {
        public StringName ObjectId;
        public Vector3 Position;
        public Vector2I Cell;
        public int CapabilityFlags;
    }

    private readonly List<Entry> _entries = new();
    private readonly Dictionary<Vector2I, List<int>> _byCell = new();

    public void Clear()
    {
        _entries.Clear();
        _byCell.Clear();
    }

    public int Count => _entries.Count;

    public void AddObject(StringName objectId, Vector3 position, Vector2I cell, int capabilityFlags)
    {
        var index = _entries.Count;
        _entries.Add(new Entry
        {
            ObjectId = objectId,
            Position = position,
            Cell = cell,
            CapabilityFlags = capabilityFlags,
        });

        if (!_byCell.TryGetValue(cell, out var list))
        {
            list = new List<int>();
            _byCell[cell] = list;
        }
        list.Add(index);
    }

    public string[] QueryCell(Vector2I cell, int capabilityMask = 0)
    {
        var result = new List<string>();
        if (!_byCell.TryGetValue(cell, out var list))
        {
            return result.ToArray();
        }

        foreach (var index in list)
        {
            var entry = _entries[index];
            if (capabilityMask == 0 || (entry.CapabilityFlags & capabilityMask) != 0)
            {
                result.Add(entry.ObjectId.ToString());
            }
        }
        return result.ToArray();
    }

    public string[] QueryRadius(Vector3 center, float radiusMeters, int capabilityMask = 0)
    {
        var result = new List<string>();
        var radiusSq = radiusMeters * radiusMeters;
        foreach (var entry in _entries)
        {
            if (capabilityMask != 0 && (entry.CapabilityFlags & capabilityMask) == 0)
            {
                continue;
            }

            if (entry.Position.DistanceSquaredTo(center) <= radiusSq)
            {
                result.Add(entry.ObjectId.ToString());
            }
        }
        return result.ToArray();
    }
}
