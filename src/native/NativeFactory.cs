using Godot;

namespace Godotwind.Native;

/// <summary>
/// Factory class for creating native C# performance implementations.
///
/// This class solves the problem that C# classes with [GlobalClass] are NOT
/// registered in ClassDB (that's only for GDExtension). Instead, this factory
/// can be loaded via GDScript's load() and used to instantiate other native classes.
///
/// Usage from GDScript:
///   var factory_script = load("res://src/native/NativeFactory.cs")
///   var factory = factory_script.new()
///   var nif_reader = factory.CreateNIFReader()
/// </summary>
[GlobalClass]
public partial class NativeFactory : RefCounted
{
    /// <summary>
    /// Check if the native C# code is available and working.
    /// </summary>
    public bool IsAvailable()
    {
        return true;
    }

    /// <summary>
    /// Get the factory version for debugging.
    /// </summary>
    public string GetVersion()
    {
        return "1.0.0";
    }

    // =========================================================================
    // NIF Processing
    // =========================================================================

    /// <summary>
    /// Create a new NIF reader instance for high-performance NIF parsing.
    /// ~20-50x faster than GDScript implementation.
    /// </summary>
    public NativeNIFReader CreateNIFReader()
    {
        return new NativeNIFReader();
    }

    /// <summary>
    /// Create a new NIF converter instance for mesh conversion.
    /// ~2-5x faster than GDScript implementation.
    /// </summary>
    public NativeNIFConverter CreateNIFConverter()
    {
        return new NativeNIFConverter();
    }

    /// <summary>
    /// Parse a NIF file from a byte buffer and return the reader.
    /// Convenience method that creates reader, loads buffer, and returns it.
    /// Returns null on parse failure.
    /// </summary>
    public NativeNIFReader? ParseNIFBuffer(byte[] data, string pathHint = "")
    {
        var reader = new NativeNIFReader();
        var error = reader.LoadBuffer(data, pathHint);
        if (error != Error.Ok)
        {
            GD.PushError($"NativeFactory: Failed to parse NIF: {pathHint} (error {error})");
            return null;
        }
        return reader;
    }

    /// <summary>
    /// Parse a NIF file from disk and return the reader.
    /// Returns null on parse failure.
    /// </summary>
    public NativeNIFReader? ParseNIFFile(string path)
    {
        var reader = new NativeNIFReader();
        var error = reader.LoadFile(path);
        if (error != Error.Ok)
        {
            GD.PushError($"NativeFactory: Failed to load NIF file: {path} (error {error})");
            return null;
        }
        return reader;
    }

    /// <summary>
    /// Full native NIF pipeline: Parse + Convert to Godot Node3D in one call.
    /// This is the fastest way to load NIF models - 20-50x faster than GDScript.
    ///
    /// Returns a SceneConversionResult containing:
    /// - RootNode: Node3D with MeshInstance3D children (geometry is ready)
    /// - TexturePaths: List of texture paths for GDScript to load
    /// - Material info stored as metadata on each MeshInstance3D
    ///
    /// Usage from GDScript:
    ///   var result = factory.ConvertNIFToScene(buffer, "model.nif")
    ///   if result.get_Success():
    ///       var node = result.get_RootNode()
    ///       add_child(node)
    ///       # Apply textures using result.get_TexturePaths()
    /// </summary>
    public NativeNIFConverter.SceneConversionResult ConvertNIFToScene(byte[] nifData, string pathHint = "")
    {
        var converter = new NativeNIFConverter();
        return converter.ConvertNIFToScene(nifData, pathHint);
    }

    /// <summary>
    /// Convert a pre-parsed NIF reader to a scene.
    /// Use when you already have a NativeNIFReader from ParseNIFBuffer().
    /// </summary>
    public NativeNIFConverter.SceneConversionResult ConvertReaderToScene(NativeNIFReader reader, string pathHint = "")
    {
        var converter = new NativeNIFConverter();
        return converter.ConvertReaderToScene(reader, pathHint);
    }

    // =========================================================================
    // BSA Processing
    // =========================================================================

    /// <summary>
    /// Create a new BSA reader instance for archive access.
    /// </summary>
    public NativeBSAReader CreateBSAReader()
    {
        return new NativeBSAReader();
    }

    // =========================================================================
    // ESM Processing
    // =========================================================================

    /// <summary>
    /// Create a new ESM reader instance for low-level binary parsing.
    /// </summary>
    public NativeESMReader CreateESMReader()
    {
        return new NativeESMReader();
    }

    /// <summary>
    /// Create a new ESM loader instance for high-level record loading.
    /// This is the recommended way to load ESM files - 10-30x faster than GDScript.
    ///
    /// Usage from GDScript:
    ///   var loader = factory.CreateESMLoader()
    ///   loader.LoadFile("Morrowind.esm", true)  # lazy references
    ///   var cell = loader.ExteriorCells["0,0"]
    ///   var model_path = loader.GetModelPath("barrel_01")
    /// </summary>
    public NativeESMLoader CreateESMLoader()
    {
        return new NativeESMLoader();
    }

    /// <summary>
    /// Load an ESM file and return the populated loader.
    /// Convenience method that creates loader and loads the file.
    /// Returns null on load failure.
    /// </summary>
    public NativeESMLoader? LoadESMFile(string path, bool lazyLoadReferences = true)
    {
        var loader = new NativeESMLoader();
        var error = loader.LoadFile(path, lazyLoadReferences);
        if (error != Error.Ok)
        {
            GD.PushError($"NativeFactory: Failed to load ESM file: {path}");
            return null;
        }
        return loader;
    }

    /// <summary>
    /// Load an ESM file with caching support (uses default cache path).
    /// If a valid cache exists, loads from cache (fast path: ~50ms).
    /// Otherwise loads from ESM file and saves cache for next time.
    /// Returns null on failure.
    /// </summary>
    public NativeESMLoader LoadESMFileWithCache(string esmPath)
    {
        return LoadESMFileWithCachePath(esmPath, ESMCache.GetDefaultCachePath(esmPath));
    }

    /// <summary>
    /// Load an ESM file with caching support (custom cache path).
    /// If a valid cache exists, loads from cache (fast path: ~50ms).
    /// Otherwise loads from ESM file and saves cache for next time.
    /// Returns null on failure.
    /// </summary>
    public NativeESMLoader LoadESMFileWithCachePath(string esmPath, string cachePath)
    {
        var loader = new NativeESMLoader();
        var cache = new ESMCache();

        // Try loading from cache first
        if (ESMCache.CacheExists(esmPath, cachePath))
        {
            GD.Print($"NativeFactory: Loading ESM from cache: {cachePath}");
            var error = cache.Load(loader, cachePath);
            if (error == Error.Ok)
            {
                GD.Print($"NativeFactory: Cache loaded in {cache.LoadTimeMs:F1}ms");
                return loader;
            }
            GD.PushWarning($"NativeFactory: Cache load failed, falling back to ESM: {cache.LastError}");
        }

        // Load from ESM file
        GD.Print($"NativeFactory: Loading ESM file: {esmPath}");
        var loadError = loader.LoadFile(esmPath, false);
        if (loadError != Error.Ok)
        {
            GD.PushError($"NativeFactory: Failed to load ESM file: {esmPath}");
            return null!;
        }

        // Save cache for next time
        var saveError = cache.Save(loader, esmPath, cachePath);
        if (saveError != Error.Ok)
        {
            GD.PushWarning($"NativeFactory: Failed to save cache: {cache.LastError}");
        }

        return loader;
    }

    /// <summary>
    /// Create an ESM cache instance.
    /// </summary>
    public ESMCache CreateESMCache()
    {
        return new ESMCache();
    }

    /// <summary>
    /// Check if a valid ESM cache exists.
    /// </summary>
    public bool ESMCacheExists(string esmPath)
    {
        return ESMCache.CacheExists(esmPath, ESMCache.GetDefaultCachePath(esmPath));
    }

    /// <summary>
    /// Get the default cache path for an ESM file.
    /// </summary>
    public string GetESMCachePath(string esmPath)
    {
        return ESMCache.GetDefaultCachePath(esmPath);
    }

    // =========================================================================
    // Terrain Generation
    // =========================================================================

    /// <summary>
    /// Create a new terrain generator instance.
    /// </summary>
    public TerrainGenerator CreateTerrainGenerator()
    {
        return new TerrainGenerator();
    }

    // =========================================================================
    // Utility
    // =========================================================================

    /// <summary>
    /// Create a high-performance binary reader.
    /// </summary>
    public NativeBinaryReader CreateBinaryReader()
    {
        return new NativeBinaryReader();
    }
}
