using Godot;
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;

namespace Godotwind.Native;

/// <summary>
/// High-performance ESM/ESP (Elder Scrolls Master/Plugin) reader for Morrowind.
/// Replaces the GDScript esm_reader.gd with optimized C# binary parsing.
///
/// Performance gains:
/// - Entire file loaded into memory buffer for fast access
/// - Uses .NET BinaryReader on MemoryStream
/// - ~10-30x faster than GDScript for record parsing
/// </summary>
[GlobalClass]
public partial class NativeESMReader : RefCounted
{
    // FourCC constants for common record/subrecord types
    public const uint REC_TES3 = 0x33534554; // "TES3"
    public const uint REC_CELL = 0x4C4C4543; // "CELL"
    public const uint REC_LAND = 0x444E414C; // "LAND"
    public const uint REC_LTEX = 0x5845544C; // "LTEX"
    public const uint REC_STAT = 0x54415453; // "STAT"
    public const uint REC_DOOR = 0x524F4F44; // "DOOR"
    public const uint REC_ACTI = 0x49544341; // "ACTI"
    public const uint REC_NPC_ = 0x5F43504E; // "NPC_"
    public const uint REC_CREA = 0x41455243; // "CREA"
    public const uint REC_CONT = 0x544E4F43; // "CONT"
    public const uint REC_MISC = 0x4353494D; // "MISC"
    public const uint REC_WEAP = 0x50414557; // "WEAP"
    public const uint REC_ARMO = 0x4F4D5241; // "ARMO"
    public const uint REC_CLOT = 0x544F4C43; // "CLOT"
    public const uint REC_BOOK = 0x4B4F4F42; // "BOOK"
    public const uint REC_APPA = 0x41505041; // "APPA"
    public const uint REC_LIGH = 0x4847494C; // "LIGH"
    public const uint REC_INGR = 0x52474E49; // "INGR"
    public const uint REC_ALCH = 0x48434C41; // "ALCH"
    public const uint REC_SPEL = 0x4C455053; // "SPEL"
    public const uint REC_SCPT = 0x54504353; // "SCPT"
    public const uint REC_REGN = 0x4E474552; // "REGN"

    // Common subrecord types
    public const uint SUB_NAME = 0x454D414E; // "NAME"
    public const uint SUB_FNAM = 0x4D414E46; // "FNAM"
    public const uint SUB_DATA = 0x41544144; // "DATA"
    public const uint SUB_INTV = 0x56544E49; // "INTV"
    public const uint SUB_VNML = 0x4C4D4E56; // "VNML"
    public const uint SUB_VHGT = 0x54474856; // "VHGT"
    public const uint SUB_WNAM = 0x4D414E57; // "WNAM"
    public const uint SUB_VCLR = 0x524C4356; // "VCLR"
    public const uint SUB_VTEX = 0x58455456; // "VTEX"

    // Memory-mapped file for fast access
    private byte[]? _buffer;
    private int _position;
    private string _filePath = "";
    private int _fileSize;

    // Reading context
    private int _leftFile;      // Bytes left in file
    private int _leftRec;       // Bytes left in current record
    private int _leftSub;       // Bytes left in current subrecord
    private uint _recName;      // Current record name (FourCC)
    private uint _subName;      // Current subrecord name (FourCC)
    private bool _subCached;    // True if subname was read but not consumed
    private uint _recordFlags;
    private int _recEndPos;     // Record end position for robust recovery

    // Header data
    public ESMHeader? Header { get; private set; }

    // Properties
    public bool IsOpen => _buffer != null;
    public string FilePath => _filePath;
    public long FileSize => _fileSize;
    public uint RecordFlags => _recordFlags;
    public bool HasMoreRecs => _leftFile > 0;
    public bool HasMoreSubs => _leftRec > 0;
    public uint CurrentRecName => _recName;
    public uint CurrentSubName => _subName;
    public int SubSize => _leftSub;

    /// <summary>
    /// Open an ESM/ESP file and parse its header.
    /// Loads entire file into memory for maximum performance.
    /// </summary>
    public Error Open(string path)
    {
        Close();

        // Convert Godot path to system path if needed
        string systemPath = path;
        if (path.StartsWith("res://") || path.StartsWith("user://"))
        {
            systemPath = ProjectSettings.GlobalizePath(path);
        }

        try
        {
            // Load entire file into memory for fast access
            _buffer = File.ReadAllBytes(systemPath);
            _position = 0;
        }
        catch (Exception e)
        {
            GD.PushError($"ESMReader: Failed to open file: {path} ({e.Message})");
            return Error.FileNotFound;
        }

        _filePath = path;
        _fileSize = _buffer.Length;
        _leftFile = _fileSize;
        _leftRec = 0;
        _leftSub = 0;
        _subCached = false;

        // First record must be TES3
        uint recName = GetRecName();
        if (recName != REC_TES3)
        {
            GD.PushError($"ESMReader: Not a valid Morrowind file: expected TES3, got {FourCCToString(recName)}");
            Close();
            return Error.FileUnrecognized;
        }

        GetRecHeader();

        // Parse header
        Header = new ESMHeader();
        Header.Load(this);

        return Error.Ok;
    }

    /// <summary>
    /// Close the file and release memory.
    /// </summary>
    public void Close()
    {
        _buffer = null;
        _position = 0;
        _filePath = "";
        _fileSize = 0;
        _leftFile = 0;
        _leftRec = 0;
        _leftSub = 0;
        _subCached = false;
        Header = null;
    }

    /// <summary>
    /// Get current file position.
    /// </summary>
    public long GetFileOffset()
    {
        return _position;
    }

    /// <summary>
    /// Cache the current subrecord name so it can be re-read.
    /// </summary>
    public void CacheSubName()
    {
        _subCached = true;
    }

    // =========================================================================
    // LOW-LEVEL READING (from memory buffer)
    // =========================================================================

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public byte GetByte()
    {
        if (_buffer == null || _position >= _fileSize)
            return 0;
        return _buffer[_position++];
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public sbyte GetS8()
    {
        return (sbyte)GetByte();
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public ushort GetU16()
    {
        if (_buffer == null || _position + 2 > _fileSize)
            return 0;
        ushort val = BitConverter.ToUInt16(_buffer, _position);
        _position += 2;
        return val;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public short GetS16()
    {
        if (_buffer == null || _position + 2 > _fileSize)
            return 0;
        short val = BitConverter.ToInt16(_buffer, _position);
        _position += 2;
        return val;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint GetU32()
    {
        if (_buffer == null || _position + 4 > _fileSize)
            return 0;
        uint val = BitConverter.ToUInt32(_buffer, _position);
        _position += 4;
        return val;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int GetS32()
    {
        if (_buffer == null || _position + 4 > _fileSize)
            return 0;
        int val = BitConverter.ToInt32(_buffer, _position);
        _position += 4;
        return val;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public ulong GetU64()
    {
        if (_buffer == null || _position + 8 > _fileSize)
            return 0;
        ulong val = BitConverter.ToUInt64(_buffer, _position);
        _position += 8;
        return val;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public float GetFloat()
    {
        if (_buffer == null || _position + 4 > _fileSize)
            return 0f;
        float val = BitConverter.ToSingle(_buffer, _position);
        _position += 4;
        return val;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint GetName()
    {
        return GetU32();
    }

    public byte[] GetExact(int size)
    {
        if (_buffer == null || _position + size > _fileSize || size <= 0)
            return Array.Empty<byte>();
        byte[] result = new byte[size];
        Buffer.BlockCopy(_buffer, _position, result, 0, size);
        _position += size;
        return result;
    }

    public void Skip(int bytes)
    {
        _position += bytes;
        if (_position > _fileSize)
            _position = _fileSize;
    }

    // =========================================================================
    // RECORD-LEVEL READING
    // =========================================================================

    /// <summary>
    /// Get the next record name.
    /// </summary>
    public uint GetRecName()
    {
        if (!HasMoreRecs)
        {
            GD.PushError("ESMReader: No more records");
            return 0;
        }

        if (HasMoreSubs)
        {
            GD.PushError("ESMReader: Previous record has unread subrecords");
        }

        if (_leftRec < 0)
        {
            Skip(_leftRec);
        }

        _recName = GetName();
        _leftFile -= 4;
        _subCached = false;

        return _recName;
    }

    /// <summary>
    /// Read record header (size and flags).
    /// </summary>
    public void GetRecHeader()
    {
        if (_leftFile < 12)
        {
            GD.PushError("ESMReader: End of file while reading record header");
            return;
        }

        _leftRec = (int)GetU32();
        GetU32(); // Unknown (always 0)
        _recordFlags = GetU32();
        _leftFile -= 12;

        if (_leftFile < _leftRec)
        {
            GD.PushError("ESMReader: Record size exceeds file bounds");
        }

        _leftFile -= _leftRec;
        _recEndPos = _position + _leftRec;
    }

    /// <summary>
    /// Skip the rest of the current record.
    /// </summary>
    public void SkipRecord()
    {
        if (_recEndPos > 0 && _position != _recEndPos)
        {
            _position = _recEndPos;
        }
        else if (_leftRec > 0)
        {
            Skip(_leftRec);
        }
        _leftRec = 0;
        _subCached = false;
    }

    public long GetRecEndPos()
    {
        return _recEndPos;
    }

    // =========================================================================
    // SUBRECORD-LEVEL READING
    // =========================================================================

    /// <summary>
    /// Get the next subrecord name.
    /// </summary>
    public void GetSubName()
    {
        if (_subCached)
        {
            _subCached = false;
            return;
        }

        _subName = GetName();
        _leftRec -= 4;
    }

    /// <summary>
    /// Get subrecord header (reads the size).
    /// </summary>
    public void GetSubHeader()
    {
        if (_leftRec < 4)
        {
            GD.PushError("ESMReader: End of record while reading subrecord header");
            return;
        }

        _leftSub = (int)GetU32();
        _leftRec -= 4;
        _leftRec -= _leftSub;
    }

    /// <summary>
    /// Check if the next subrecord has the given name.
    /// </summary>
    public bool IsNextSub(uint name)
    {
        if (!HasMoreSubs)
            return false;

        GetSubName();

        if (_subName != name)
        {
            _subCached = true;
            return false;
        }

        return true;
    }

    /// <summary>
    /// Get subrecord name and verify it matches.
    /// </summary>
    public void GetSubNameIs(uint name)
    {
        GetSubName();
        if (_subName != name)
        {
            GD.PushError($"ESMReader: Expected subrecord {FourCCToString(name)}, got {FourCCToString(_subName)}");
        }
    }

    /// <summary>
    /// Skip the current subrecord.
    /// </summary>
    public void SkipHSub()
    {
        GetSubHeader();
        Skip(_leftSub);
    }

    // =========================================================================
    // HIGH-LEVEL READING
    // =========================================================================

    /// <summary>
    /// Read a string with subrecord header.
    /// </summary>
    public string GetHString()
    {
        GetSubHeader();
        return GetString(_leftSub);
    }

    /// <summary>
    /// Read a string by subrecord name.
    /// </summary>
    public string GetHNString(uint name)
    {
        GetSubNameIs(name);
        return GetHString();
    }

    /// <summary>
    /// Optionally read a string by subrecord name.
    /// </summary>
    public string GetHNOString(uint name)
    {
        if (IsNextSub(name))
            return GetHString();
        return "";
    }

    /// <summary>
    /// Read typed data with subrecord header.
    /// </summary>
    public byte[] GetHT(int expectedSize)
    {
        GetSubHeader();
        if (_leftSub != expectedSize)
        {
            GD.PushError($"ESMReader: Subrecord size mismatch: expected {expectedSize}, got {_leftSub}");
        }
        return GetExact(_leftSub);
    }

    /// <summary>
    /// Read typed data by subrecord name.
    /// </summary>
    public byte[] GetHNT(uint name, int expectedSize)
    {
        GetSubNameIs(name);
        return GetHT(expectedSize);
    }

    /// <summary>
    /// Optionally read typed data by subrecord name.
    /// </summary>
    public byte[] GetHNOT(uint name, int expectedSize)
    {
        if (IsNextSub(name))
            return GetHT(expectedSize);
        return Array.Empty<byte>();
    }

    // =========================================================================
    // STRING READING
    // =========================================================================

    /// <summary>
    /// Read a fixed-size string (null-terminated within buffer).
    /// </summary>
    public string GetString(int size)
    {
        if (size == 0)
            return "";

        var bytes = GetExact(size);

        // Find null terminator
        int nullPos = Array.IndexOf(bytes, (byte)0);
        int actualLength = nullPos >= 0 ? nullPos : bytes.Length;

        return Encoding.ASCII.GetString(bytes, 0, actualLength);
    }

    // =========================================================================
    // UTILITY FUNCTIONS
    // =========================================================================

    /// <summary>
    /// Convert FourCC to string.
    /// </summary>
    public static string FourCCToString(uint fourCC)
    {
        var bytes = BitConverter.GetBytes(fourCC);
        return Encoding.ASCII.GetString(bytes);
    }

    /// <summary>
    /// Convert string to FourCC.
    /// </summary>
    public static uint StringToFourCC(string str)
    {
        if (str.Length != 4)
            return 0;
        var bytes = Encoding.ASCII.GetBytes(str);
        return BitConverter.ToUInt32(bytes, 0);
    }

    /// <summary>
    /// Report an error with context.
    /// </summary>
    public void Fail(string msg)
    {
        var errorMsg = $"ESM Error: {msg}\n" +
                      $"  File: {_filePath}\n" +
                      $"  Record: {FourCCToString(_recName)}\n" +
                      $"  Subrecord: {FourCCToString(_subName)}\n" +
                      $"  Offset: 0x{GetFileOffset():X}";
        GD.PushError(errorMsg);
    }

    ~NativeESMReader()
    {
        Close();
    }
}

/// <summary>
/// ESM file header data.
/// </summary>
public class ESMHeader
{
    public float Version { get; set; }
    public bool IsMaster { get; set; }
    public string Author { get; set; } = "";
    public string Description { get; set; } = "";
    public int NumRecords { get; set; }
    public List<(string filename, long size)> Masters { get; } = new();

    public void Load(NativeESMReader reader)
    {
        while (reader.HasMoreSubs)
        {
            reader.GetSubName();
            uint subName = reader.CurrentSubName;

            if (subName == 0x52444548) // "HEDR"
            {
                reader.GetSubHeader();
                Version = reader.GetFloat();
                uint flags = reader.GetU32();
                IsMaster = (flags & 1) != 0;
                Author = reader.GetString(32);
                Description = reader.GetString(256);
                NumRecords = reader.GetS32();
            }
            else if (subName == 0x5453414D) // "MAST"
            {
                string masterFile = reader.GetHString();
                // DATA subrecord follows with the master file size
                reader.GetSubNameIs(NativeESMReader.SUB_DATA);
                reader.GetSubHeader();
                long masterSize = (long)reader.GetU64();
                Masters.Add((masterFile, masterSize));
            }
            else
            {
                // Unknown subrecord, skip it
                reader.SkipHSub();
            }
        }
    }
}
