using Godot;
using System.Collections.Generic;

namespace Godotwind.Native;

/// <summary>
/// Cooked per-cell world-object manifest (Phase 3 M.0, plan:
/// docs/plans/distant_rendering_recovery_2026_07.md).
///
/// Serializes the fields of GDScript WorldObjectRecord objects into a custom
/// binary file and loads them back without touching ResourceLoader — plain
/// FileAccess reads sidestep the Godot ≤4.6 threaded-loader race and never
/// queue behind the single-flight model loads.
///
/// Cooking happens OFFLINE via the prebake UI (project rule: no runtime
/// generation): the prebake tool builds the manifest through the existing
/// runtime path (WorldObjectSource.get_objects_in_cell) and hands the record
/// array here, so cooked output equals the runtime build by construction.
///
/// Derived-at-load fields (not stored): object_id, source_key,
/// adapter_payload_id, model_item_id — all pure functions of stored data,
/// mirrored from morrowind_world_object_source._make_record.
/// </summary>
[GlobalClass]
public partial class NativeCellManifest : RefCounted
{
    // "GWM1" little-endian.
    private const uint Magic = 0x314D5747;
    private const ushort FormatVersion = 1;

    private struct Rec
    {
        public int SourceRefId;   // string table index
        public int RecordId;      // string table index
        public int RefNum;
        public int ModelPath;     // string table index
        public int CacheItemId;   // string table index
        public int SourceType;    // string table index
        public byte Category;
        public byte SpawnRoute;
        public byte LightAnimation;
        public byte BoolFlags;    // bit0 static_batch_allowed, bit1 light_is_fire
        public int CapabilityFlags;
        public float ProximityRadiusM;
        public float ScaleScalar;
        public Transform3D Transform;
        public Color LightColor;
        public float LightRadius;
    }

    private readonly List<string> _strings = new();
    private readonly Dictionary<string, int> _stringIndex = new();
    private Rec[] _records = System.Array.Empty<Rec>();
    private Vector2I _cellGrid;
    private string _cellName = "";

    public string LastError { get; private set; } = "";

    public int GetRecordCount() => _records.Length;
    public Vector2I GetCellGrid() => _cellGrid;
    public string GetCellName() => _cellName;

    /// <summary>
    /// Serialize an Array of GDScript WorldObjectRecord objects to `path`.
    /// Offline path — per-record Variant marshalling cost is irrelevant here.
    /// </summary>
    public Error CookFromRecords(Vector2I cellGrid, string cellName, Godot.Collections.Array records, string path)
    {
        _cellGrid = cellGrid;
        _cellName = cellName ?? "";
        _strings.Clear();
        _stringIndex.Clear();
        InternString(""); // index 0 = empty

        var recs = new Rec[records.Count];
        for (int i = 0; i < records.Count; i++)
        {
            var obj = records[i].AsGodotObject();
            if (obj == null)
            {
                LastError = $"record {i} is not an object";
                return Error.InvalidData;
            }

            var objectId = obj.Get("object_id").AsString();
            var refNum = ParseRefNum(objectId);
            if (refNum == int.MinValue)
            {
                LastError = $"record {i}: cannot parse ref_num from object_id '{objectId}'";
                return Error.InvalidData;
            }

            var boolFlags = 0;
            if (obj.Get("static_batch_allowed").AsBool())
            {
                boolFlags |= 1;
            }
            if (obj.Get("light_is_fire").AsBool())
            {
                boolFlags |= 2;
            }

            recs[i] = new Rec
            {
                SourceRefId = InternString(obj.Get("source_ref_id").AsString()),
                RecordId = InternString(obj.Get("record_id").AsString()),
                RefNum = refNum,
                ModelPath = InternString(obj.Get("model_path").AsString()),
                CacheItemId = InternString(obj.Get("cache_item_id").AsString()),
                SourceType = InternString(obj.Get("source_type").AsString()),
                Category = (byte)obj.Get("category").AsInt32(),
                SpawnRoute = (byte)obj.Get("spawn_route").AsInt32(),
                LightAnimation = (byte)obj.Get("light_animation").AsInt32(),
                BoolFlags = (byte)boolFlags,
                CapabilityFlags = obj.Get("capability_flags").AsInt32(),
                ProximityRadiusM = (float)obj.Get("proximity_radius_m").AsDouble(),
                ScaleScalar = (float)obj.Get("scale_scalar").AsDouble(),
                Transform = obj.Get("transform").AsTransform3D(),
                LightColor = obj.Get("light_color").AsColor(),
                LightRadius = (float)obj.Get("light_radius").AsDouble(),
            };
        }
        _records = recs;

        using var f = FileAccess.Open(path, FileAccess.ModeFlags.Write);
        if (f == null)
        {
            LastError = $"open for write failed: {FileAccess.GetOpenError()}";
            return FileAccess.GetOpenError();
        }

        f.Store32(Magic);
        f.Store16(FormatVersion);
        f.Store16(0); // reserved
        f.Store32((uint)_cellGrid.X);
        f.Store32((uint)_cellGrid.Y);
        StoreString(f, _cellName);

        f.Store32((uint)_strings.Count);
        foreach (var s in _strings)
        {
            StoreString(f, s);
        }

        f.Store32((uint)_records.Length);
        foreach (var r in _records)
        {
            f.Store32((uint)r.SourceRefId);
            f.Store32((uint)r.RecordId);
            f.Store32((uint)r.RefNum);
            f.Store32((uint)r.ModelPath);
            f.Store32((uint)r.CacheItemId);
            f.Store32((uint)r.SourceType);
            f.Store8(r.Category);
            f.Store8(r.SpawnRoute);
            f.Store8(r.LightAnimation);
            f.Store8(r.BoolFlags);
            f.Store32((uint)r.CapabilityFlags);
            f.StoreFloat(r.ProximityRadiusM);
            f.StoreFloat(r.ScaleScalar);
            StoreTransform(f, r.Transform);
            f.StoreFloat(r.LightColor.R);
            f.StoreFloat(r.LightColor.G);
            f.StoreFloat(r.LightColor.B);
            f.StoreFloat(r.LightColor.A);
            f.StoreFloat(r.LightRadius);
        }
        return Error.Ok;
    }

    /// <summary>
    /// Load a cooked manifest. Safe to call from a background thread: uses
    /// plain FileAccess, no ResourceLoader, no scene-tree access.
    /// </summary>
    public Error LoadFromFile(string path)
    {
        using var f = FileAccess.Open(path, FileAccess.ModeFlags.Read);
        if (f == null)
        {
            LastError = $"open for read failed: {FileAccess.GetOpenError()}";
            return FileAccess.GetOpenError();
        }

        if (f.Get32() != Magic)
        {
            LastError = "bad magic";
            return Error.FileCorrupt;
        }
        var version = f.Get16();
        if (version != FormatVersion)
        {
            LastError = $"unsupported version {version}";
            return Error.FileCorrupt;
        }
        f.Get16(); // reserved
        _cellGrid = new Vector2I((int)f.Get32(), (int)f.Get32());
        _cellName = GetString(f);

        _strings.Clear();
        _stringIndex.Clear();
        var stringCount = f.Get32();
        for (uint i = 0; i < stringCount; i++)
        {
            _strings.Add(GetString(f));
        }

        var recordCount = f.Get32();
        var recs = new Rec[recordCount];
        for (uint i = 0; i < recordCount; i++)
        {
            recs[i] = new Rec
            {
                SourceRefId = (int)f.Get32(),
                RecordId = (int)f.Get32(),
                RefNum = (int)f.Get32(),
                ModelPath = (int)f.Get32(),
                CacheItemId = (int)f.Get32(),
                SourceType = (int)f.Get32(),
                Category = f.Get8(),
                SpawnRoute = f.Get8(),
                LightAnimation = f.Get8(),
                BoolFlags = f.Get8(),
                CapabilityFlags = (int)f.Get32(),
                ProximityRadiusM = f.GetFloat(),
                ScaleScalar = f.GetFloat(),
                Transform = GetTransform(f),
                LightColor = new Color(f.GetFloat(), f.GetFloat(), f.GetFloat(), f.GetFloat()),
                LightRadius = f.GetFloat(),
            };
        }
        _records = recs;
        return Error.Ok;
    }

    /// <summary>
    /// Full field set for one record, including the derived fields, keyed by
    /// the exact WorldObjectRecord property names so GDScript can hydrate a
    /// record (or, in M.1, consume the values directly).
    /// </summary>
    public Godot.Collections.Dictionary GetRecordFields(int index)
    {
        var r = _records[index];
        var sourceRefId = _strings[r.SourceRefId];
        var recordId = _strings[r.RecordId];
        var sourceType = _strings[r.SourceType];
        var objectId = MakeObjectId(sourceRefId, r.RefNum);

        return new Godot.Collections.Dictionary
        {
            { "object_id", objectId },
            { "record_id", recordId },
            { "source_ref_id", sourceRefId },
            { "source_key", $"{sourceType}:{objectId}" },
            { "cell_grid", _cellGrid },
            { "transform", r.Transform },
            { "model_path", _strings[r.ModelPath] },
            { "model_item_id", recordId },
            { "cache_item_id", _strings[r.CacheItemId] },
            { "category", (int)r.Category },
            { "capability_flags", r.CapabilityFlags },
            { "spawn_route", (int)r.SpawnRoute },
            { "static_batch_allowed", (r.BoolFlags & 1) != 0 },
            { "proximity_radius_m", r.ProximityRadiusM },
            { "adapter_payload_id", objectId },
            { "source_type", sourceType },
            { "scale_scalar", r.ScaleScalar },
            { "light_color", r.LightColor },
            { "light_radius", r.LightRadius },
            { "light_animation", (int)r.LightAnimation },
            { "light_is_fire", (r.BoolFlags & 2) != 0 },
        };
    }

    // Mirrors world_object_record.make_object_id and the interior variant in
    // morrowind_world_object_source._make_object_id.
    private string MakeObjectId(string sourceRefId, int refNum)
    {
        if (string.IsNullOrEmpty(_cellName))
        {
            return $"{_cellGrid.X},{_cellGrid.Y}:{sourceRefId.ToLowerInvariant()}:{refNum}";
        }
        var normalized = _cellName.ToLowerInvariant().Replace(" ", "_").Replace(",", "");
        return $"interior:{normalized}:{sourceRefId.ToLowerInvariant()}:{refNum}";
    }

    // object_id always ends in ":<ref_num>" by construction (make_object_id).
    private static int ParseRefNum(string objectId)
    {
        var idx = objectId.LastIndexOf(':');
        if (idx < 0 || idx == objectId.Length - 1)
        {
            return int.MinValue;
        }
        return int.TryParse(objectId[(idx + 1)..], out var value) ? value : int.MinValue;
    }

    private int InternString(string value)
    {
        if (_stringIndex.TryGetValue(value, out var existing))
        {
            return existing;
        }
        var index = _strings.Count;
        _strings.Add(value);
        _stringIndex[value] = index;
        return index;
    }

    private static void StoreString(FileAccess f, string value)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(value);
        f.Store16((ushort)bytes.Length);
        if (bytes.Length > 0)
        {
            f.StoreBuffer(bytes);
        }
    }

    private static string GetString(FileAccess f)
    {
        var length = f.Get16();
        if (length == 0)
        {
            return "";
        }
        return System.Text.Encoding.UTF8.GetString(f.GetBuffer(length));
    }

    private static void StoreTransform(FileAccess f, Transform3D t)
    {
        f.StoreFloat(t.Basis.Column0.X); f.StoreFloat(t.Basis.Column0.Y); f.StoreFloat(t.Basis.Column0.Z);
        f.StoreFloat(t.Basis.Column1.X); f.StoreFloat(t.Basis.Column1.Y); f.StoreFloat(t.Basis.Column1.Z);
        f.StoreFloat(t.Basis.Column2.X); f.StoreFloat(t.Basis.Column2.Y); f.StoreFloat(t.Basis.Column2.Z);
        f.StoreFloat(t.Origin.X); f.StoreFloat(t.Origin.Y); f.StoreFloat(t.Origin.Z);
    }

    private static Transform3D GetTransform(FileAccess f)
    {
        var c0 = new Vector3(f.GetFloat(), f.GetFloat(), f.GetFloat());
        var c1 = new Vector3(f.GetFloat(), f.GetFloat(), f.GetFloat());
        var c2 = new Vector3(f.GetFloat(), f.GetFloat(), f.GetFloat());
        var origin = new Vector3(f.GetFloat(), f.GetFloat(), f.GetFloat());
        return new Transform3D(new Basis(c0, c1, c2), origin);
    }
}
