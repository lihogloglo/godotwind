using Godot;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Godotwind.Native;

/// <summary>
/// High-performance binary reader for Morrowind file formats (NIF, ESM, BSA).
/// Optimized for sequential reading with minimal allocations.
///
/// Performance gains over GDScript:
/// - Direct buffer access (no method call overhead per byte)
/// - Native endian handling
/// - Span-based string reading (no intermediate allocations)
/// - ~20-50x faster than GDScript for binary parsing
/// </summary>
public ref struct FastBinaryReader
{
    private readonly ReadOnlySpan<byte> _buffer;
    private int _position;

    public FastBinaryReader(byte[] buffer)
    {
        _buffer = buffer;
        _position = 0;
    }

    public FastBinaryReader(ReadOnlySpan<byte> buffer)
    {
        _buffer = buffer;
        _position = 0;
    }

    public int Position
    {
        get => _position;
        set => _position = value;
    }

    public int Length => _buffer.Length;
    public int Remaining => _buffer.Length - _position;
    public bool IsEof => _position >= _buffer.Length;

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public byte ReadByte()
    {
        if (_position >= _buffer.Length)
            return 0;
        return _buffer[_position++];
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public sbyte ReadSByte()
    {
        return (sbyte)ReadByte();
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public ushort ReadUInt16()
    {
        if (_position + 2 > _buffer.Length)
            return 0;
        ushort value = (ushort)(_buffer[_position] | (_buffer[_position + 1] << 8));
        _position += 2;
        return value;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public short ReadInt16()
    {
        return (short)ReadUInt16();
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint ReadUInt32()
    {
        if (_position + 4 > _buffer.Length)
            return 0;
        uint value = (uint)(_buffer[_position] |
                          (_buffer[_position + 1] << 8) |
                          (_buffer[_position + 2] << 16) |
                          (_buffer[_position + 3] << 24));
        _position += 4;
        return value;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public int ReadInt32()
    {
        return (int)ReadUInt32();
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public ulong ReadUInt64()
    {
        if (_position + 8 > _buffer.Length)
            return 0;
        ulong lo = ReadUInt32();
        ulong hi = ReadUInt32();
        return lo | (hi << 32);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public long ReadInt64()
    {
        return (long)ReadUInt64();
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public unsafe float ReadFloat()
    {
        if (_position + 4 > _buffer.Length)
            return 0f;

        uint bits = ReadUInt32();
        _position -= 4; // ReadUInt32 advanced, we'll manually advance
        float result = BitConverter.UInt32BitsToSingle(bits);
        _position += 4;
        return result;
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public Vector3 ReadVector3()
    {
        float x = ReadFloat();
        float y = ReadFloat();
        float z = ReadFloat();
        return new Vector3(x, y, z);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public Vector2 ReadVector2()
    {
        float x = ReadFloat();
        float y = ReadFloat();
        return new Vector2(x, y);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public Quaternion ReadQuaternion()
    {
        // NIF uses WXYZ order
        float w = ReadFloat();
        float x = ReadFloat();
        float y = ReadFloat();
        float z = ReadFloat();
        return new Quaternion(x, y, z, w);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public Basis ReadMatrix3()
    {
        // Row-major 3x3 matrix
        var x = new Vector3(ReadFloat(), ReadFloat(), ReadFloat());
        var y = new Vector3(ReadFloat(), ReadFloat(), ReadFloat());
        var z = new Vector3(ReadFloat(), ReadFloat(), ReadFloat());
        return new Basis(x, y, z);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public Color ReadColor3()
    {
        float r = ReadFloat();
        float g = ReadFloat();
        float b = ReadFloat();
        return new Color(r, g, b, 1.0f);
    }

    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public Color ReadColor4()
    {
        float r = ReadFloat();
        float g = ReadFloat();
        float b = ReadFloat();
        float a = ReadFloat();
        return new Color(r, g, b, a);
    }

    /// <summary>
    /// Read a length-prefixed string (uint32 length + ASCII bytes).
    /// </summary>
    public string ReadString()
    {
        uint length = ReadUInt32();
        if (length == 0 || length > 65535 || _position + length > _buffer.Length)
        {
            if (length > 65535)
                GD.PushError($"FastBinaryReader: Invalid string length {length} at pos {_position}");
            return "";
        }

        var span = _buffer.Slice(_position, (int)length);
        _position += (int)length;
        return Encoding.ASCII.GetString(span);
    }

    /// <summary>
    /// Read a null-terminated string from a fixed-size buffer.
    /// </summary>
    public string ReadFixedString(int maxLength)
    {
        if (_position + maxLength > _buffer.Length)
            return "";

        int nullPos = -1;
        for (int i = 0; i < maxLength; i++)
        {
            if (_buffer[_position + i] == 0)
            {
                nullPos = i;
                break;
            }
        }

        int actualLength = nullPos >= 0 ? nullPos : maxLength;
        var span = _buffer.Slice(_position, actualLength);
        _position += maxLength; // Always advance by fixed size
        return Encoding.ASCII.GetString(span);
    }

    /// <summary>
    /// Read until newline character.
    /// </summary>
    public string ReadLine()
    {
        int start = _position;
        while (_position < _buffer.Length && _buffer[_position] != '\n')
            _position++;

        int end = _position;
        if (_position < _buffer.Length)
            _position++; // Skip newline

        var span = _buffer.Slice(start, end - start);
        return Encoding.ASCII.GetString(span);
    }

    /// <summary>
    /// Read a FourCC code as a string.
    /// </summary>
    public string ReadFourCC()
    {
        if (_position + 4 > _buffer.Length)
            return "";

        var span = _buffer.Slice(_position, 4);
        _position += 4;
        return Encoding.ASCII.GetString(span);
    }

    /// <summary>
    /// Read raw bytes into a new array.
    /// </summary>
    public byte[] ReadBytes(int count)
    {
        if (_position + count > _buffer.Length)
            count = _buffer.Length - _position;

        var result = new byte[count];
        _buffer.Slice(_position, count).CopyTo(result);
        _position += count;
        return result;
    }

    /// <summary>
    /// Skip bytes.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public void Skip(int count)
    {
        _position += count;
    }

    /// <summary>
    /// Peek at the next byte without advancing position.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public byte PeekByte()
    {
        if (_position >= _buffer.Length)
            return 0;
        return _buffer[_position];
    }

    /// <summary>
    /// Peek at the next uint32 without advancing position.
    /// </summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    public uint PeekUInt32()
    {
        if (_position + 4 > _buffer.Length)
            return 0;
        return (uint)(_buffer[_position] |
                     (_buffer[_position + 1] << 8) |
                     (_buffer[_position + 2] << 16) |
                     (_buffer[_position + 3] << 24));
    }
}

/// <summary>
/// Godot-compatible wrapper for FastBinaryReader that can be used from GDScript.
/// Holds a byte array and provides reading methods.
/// </summary>
[GlobalClass]
public partial class NativeBinaryReader : RefCounted
{
    private byte[] _buffer = Array.Empty<byte>();
    private int _position;

    public int Position
    {
        get => _position;
        set => _position = Math.Clamp(value, 0, _buffer.Length);
    }

    public int Length => _buffer.Length;
    public int Remaining => _buffer.Length - _position;
    public bool IsEof => _position >= _buffer.Length;

    /// <summary>
    /// Load data from a byte array.
    /// </summary>
    public void LoadFromBuffer(byte[] data)
    {
        _buffer = data ?? Array.Empty<byte>();
        _position = 0;
    }

    /// <summary>
    /// Load data from a Godot PackedByteArray.
    /// </summary>
    public void LoadFromPackedArray(byte[] data)
    {
        _buffer = data ?? Array.Empty<byte>();
        _position = 0;
    }

    /// <summary>
    /// Load data from a file path.
    /// </summary>
    public Error LoadFromFile(string path)
    {
        using var file = FileAccess.Open(path, FileAccess.ModeFlags.Read);
        if (file == null)
            return FileAccess.GetOpenError();

        _buffer = file.GetBuffer((long)file.GetLength());
        _position = 0;
        return Error.Ok;
    }

    // Reading methods - wrapper around FastBinaryReader
    public byte ReadByte() => _position < _buffer.Length ? _buffer[_position++] : (byte)0;
    public int ReadSByte() => (sbyte)ReadByte();

    public int ReadUInt16()
    {
        if (_position + 2 > _buffer.Length) return 0;
        int v = _buffer[_position] | (_buffer[_position + 1] << 8);
        _position += 2;
        return v;
    }

    public int ReadInt16() => (short)ReadUInt16();

    public long ReadUInt32()
    {
        if (_position + 4 > _buffer.Length) return 0;
        uint v = (uint)(_buffer[_position] |
                       (_buffer[_position + 1] << 8) |
                       (_buffer[_position + 2] << 16) |
                       (_buffer[_position + 3] << 24));
        _position += 4;
        return v;
    }

    public int ReadInt32() => (int)ReadUInt32();

    public float ReadFloat()
    {
        if (_position + 4 > _buffer.Length) return 0f;
        uint bits = (uint)(_buffer[_position] |
                         (_buffer[_position + 1] << 8) |
                         (_buffer[_position + 2] << 16) |
                         (_buffer[_position + 3] << 24));
        _position += 4;
        return BitConverter.UInt32BitsToSingle(bits);
    }

    public Vector3 ReadVector3() => new(ReadFloat(), ReadFloat(), ReadFloat());
    public Vector2 ReadVector2() => new(ReadFloat(), ReadFloat());

    public Quaternion ReadQuaternion()
    {
        float w = ReadFloat();
        float x = ReadFloat();
        float y = ReadFloat();
        float z = ReadFloat();
        return new Quaternion(x, y, z, w);
    }

    public Basis ReadMatrix3()
    {
        var x = new Vector3(ReadFloat(), ReadFloat(), ReadFloat());
        var y = new Vector3(ReadFloat(), ReadFloat(), ReadFloat());
        var z = new Vector3(ReadFloat(), ReadFloat(), ReadFloat());
        return new Basis(x, y, z);
    }

    public Color ReadColor3() => new(ReadFloat(), ReadFloat(), ReadFloat(), 1.0f);
    public Color ReadColor4() => new(ReadFloat(), ReadFloat(), ReadFloat(), ReadFloat());

    public string ReadString()
    {
        long length = ReadUInt32();
        if (length == 0 || length > 65535 || _position + length > _buffer.Length)
            return "";

        var span = new ReadOnlySpan<byte>(_buffer, _position, (int)length);
        _position += (int)length;
        return Encoding.ASCII.GetString(span);
    }

    public string ReadFixedString(int maxLength)
    {
        if (_position + maxLength > _buffer.Length)
            return "";

        int nullPos = Array.IndexOf(_buffer, (byte)0, _position, maxLength);
        int actualLength = nullPos >= 0 ? nullPos - _position : maxLength;

        var span = new ReadOnlySpan<byte>(_buffer, _position, actualLength);
        _position += maxLength;
        return Encoding.ASCII.GetString(span);
    }

    public string ReadLine()
    {
        int start = _position;
        while (_position < _buffer.Length && _buffer[_position] != '\n')
            _position++;
        int end = _position;
        if (_position < _buffer.Length)
            _position++;
        return Encoding.ASCII.GetString(_buffer, start, end - start);
    }

    public string ReadFourCC()
    {
        if (_position + 4 > _buffer.Length) return "";
        var span = new ReadOnlySpan<byte>(_buffer, _position, 4);
        _position += 4;
        return Encoding.ASCII.GetString(span);
    }

    public byte[] ReadBytes(int count)
    {
        if (_position + count > _buffer.Length)
            count = _buffer.Length - _position;
        var result = new byte[count];
        Array.Copy(_buffer, _position, result, 0, count);
        _position += count;
        return result;
    }

    public void Skip(int count) => _position = Math.Min(_position + count, _buffer.Length);
    public byte PeekByte() => _position < _buffer.Length ? _buffer[_position] : (byte)0;

    public long PeekUInt32()
    {
        if (_position + 4 > _buffer.Length) return 0;
        return (uint)(_buffer[_position] |
                     (_buffer[_position + 1] << 8) |
                     (_buffer[_position + 2] << 16) |
                     (_buffer[_position + 3] << 24));
    }
}
