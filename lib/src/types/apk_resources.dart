// Reads Firebase configuration back out of an installed Android APK.
// (Shared, byte for byte, with firebase_auth_kit's lib/src/core/apk_resources.dart.)
//
// The Google Services Gradle plugin turns `google-services.json` into string
// resources (`google_api_key`, `google_app_id`, `project_id`, …) that live in
// the APK's `resources.arsc`; a `google-services.json` listed under
// `dartnative: assets:` lives under `assets/flutter_assets/`. Both are plain
// files inside the APK zip, which the running app may read.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The path of the APK the current process was loaded from, or `null`.
///
/// `/proc/self/maps` lists every mapped file, including the APK that holds
/// the app's code and resources.
String? currentApkPath() {
  if (!Platform.isAndroid) return null;
  try {
    final maps = File('/proc/self/maps').readAsLinesSync();
    for (final line in maps) {
      final index = line.indexOf('/');
      if (index == -1) continue;
      final path = line.substring(index).trim();
      if (path.endsWith('/base.apk') && File(path).existsSync()) return path;
    }
    for (final line in maps) {
      final index = line.indexOf('/');
      if (index == -1) continue;
      final path = line.substring(index).trim();
      if (path.endsWith('.apk') && File(path).existsSync()) return path;
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// A zip central-directory entry.
class ZipEntry {
  ZipEntry(this.name, this._method, this._compressedSize, this._localHeaderOffset);

  final String name;
  final int _method;
  final int _compressedSize;
  final int _localHeaderOffset;
}

/// A minimal read-only zip reader that touches only the bytes it needs, so an
/// APK of tens of megabytes is never read whole.
class ZipReader {
  ZipReader._(this._file, this.entries);

  final RandomAccessFile _file;

  /// Every entry in the archive.
  final List<ZipEntry> entries;

  static const _eocdSignature = 0x06054b50;
  static const _centralSignature = 0x02014b50;
  static const _localSignature = 0x04034b50;

  /// Opens [file] and reads its central directory.
  static ZipReader open(File file) {
    final raf = file.openSync();
    try {
      final length = raf.lengthSync();
      final tailLength = length < 66000 ? length : 66000;
      raf.setPositionSync(length - tailLength);
      final tail = raf.readSync(tailLength);
      final tailData = ByteData.sublistView(tail);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tailData.getUint32(i, Endian.little) == _eocdSignature) {
          eocd = i;
          break;
        }
      }
      if (eocd == -1) {
        throw const FormatException('not a zip archive (no end-of-central-directory)');
      }
      final entryCount = tailData.getUint16(eocd + 10, Endian.little);
      final directorySize = tailData.getUint32(eocd + 12, Endian.little);
      final directoryOffset = tailData.getUint32(eocd + 16, Endian.little);
      if (directoryOffset == 0xFFFFFFFF) {
        throw const FormatException('zip64 archives are not supported');
      }
      raf.setPositionSync(directoryOffset);
      final directory = raf.readSync(directorySize);
      final data = ByteData.sublistView(directory);
      final entries = <ZipEntry>[];
      var position = 0;
      for (var i = 0; i < entryCount && position + 46 <= directory.length; i++) {
        if (data.getUint32(position, Endian.little) != _centralSignature) break;
        final method = data.getUint16(position + 10, Endian.little);
        final compressedSize = data.getUint32(position + 20, Endian.little);
        final nameLength = data.getUint16(position + 28, Endian.little);
        final extraLength = data.getUint16(position + 30, Endian.little);
        final commentLength = data.getUint16(position + 32, Endian.little);
        final localOffset = data.getUint32(position + 42, Endian.little);
        final name = utf8.decode(
          directory.sublist(position + 46, position + 46 + nameLength),
          allowMalformed: true,
        );
        entries.add(ZipEntry(name, method, compressedSize, localOffset));
        position += 46 + nameLength + extraLength + commentLength;
      }
      return ZipReader._(raf, entries);
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  /// The entry named [name], or `null`.
  ZipEntry? find(String name) {
    for (final entry in entries) {
      if (entry.name == name) return entry;
    }
    return null;
  }

  /// The decompressed bytes of [entry].
  Uint8List read(ZipEntry entry) {
    _file.setPositionSync(entry._localHeaderOffset);
    final header = _file.readSync(30);
    final data = ByteData.sublistView(header);
    if (data.getUint32(0, Endian.little) != _localSignature) {
      throw FormatException('bad local header for ${entry.name}');
    }
    final nameLength = data.getUint16(26, Endian.little);
    final extraLength = data.getUint16(28, Endian.little);
    _file.setPositionSync(entry._localHeaderOffset + 30 + nameLength + extraLength);
    final compressed = _file.readSync(entry._compressedSize);
    switch (entry._method) {
      case 0:
        return compressed;
      case 8:
        return Uint8List.fromList(ZLibDecoder(raw: true).convert(compressed));
      default:
        throw FormatException(
            'unsupported compression method ${entry._method} for ${entry.name}');
    }
  }

  void close() => _file.closeSync();
}

/// Parses the `string` resources of an Android `resources.arsc` table.
///
/// Returns `{resourceName: value}` for every string entry in the default
/// configuration (other configurations only add translations and are skipped
/// when the key is already present).
Map<String, String> parseArscStrings(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  const resTableType = 0x0002;
  const resStringPoolType = 0x0001;
  const resTablePackageType = 0x0200;
  const resTableTypeType = 0x0201;

  if (bytes.length < 12 || data.getUint16(0, Endian.little) != resTableType) {
    throw const FormatException('not a resources.arsc table');
  }
  final tableHeaderSize = data.getUint16(2, Endian.little);
  final tableSize = data.getUint32(4, Endian.little);
  final result = <String, String>{};

  var offset = tableHeaderSize;
  List<String>? globalStrings;
  while (offset + 8 <= tableSize && offset + 8 <= bytes.length) {
    final chunkType = data.getUint16(offset, Endian.little);
    final chunkHeaderSize = data.getUint16(offset + 2, Endian.little);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    if (chunkSize < 8) break;
    if (chunkType == resStringPoolType) {
      globalStrings = _readStringPool(data, bytes, offset);
    } else if (chunkType == resTablePackageType && globalStrings != null) {
      _readPackage(data, bytes, offset, chunkHeaderSize, chunkSize, globalStrings,
          resTableTypeType, result);
    }
    offset += chunkSize;
  }
  return result;
}

void _readPackage(
  ByteData data,
  Uint8List bytes,
  int packageStart,
  int headerSize,
  int packageSize,
  List<String> globalStrings,
  int resTableTypeType,
  Map<String, String> result,
) {
  final typeStringsOffset = data.getUint32(packageStart + 268, Endian.little);
  final keyStringsOffset = data.getUint32(packageStart + 276, Endian.little);
  final typeStrings = _readStringPool(data, bytes, packageStart + typeStringsOffset);
  final keyStrings = _readStringPool(data, bytes, packageStart + keyStringsOffset);
  final stringTypeId = typeStrings.indexOf('string') + 1;
  if (stringTypeId == 0) return;

  var offset = packageStart + headerSize;
  final end = packageStart + packageSize;
  while (offset + 8 <= end && offset + 8 <= bytes.length) {
    final chunkType = data.getUint16(offset, Endian.little);
    final chunkHeaderSize = data.getUint16(offset + 2, Endian.little);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    if (chunkSize < 8) break;
    if (chunkType == resTableTypeType && data.getUint8(offset + 8) == stringTypeId) {
      _readStringTypeChunk(
          data, offset, chunkHeaderSize, chunkSize, globalStrings, keyStrings, result);
    }
    offset += chunkSize;
  }
}

void _readStringTypeChunk(
  ByteData data,
  int chunkStart,
  int headerSize,
  int chunkSize,
  List<String> globalStrings,
  List<String> keyStrings,
  Map<String, String> result,
) {
  const flagSparse = 0x01;
  const entryFlagComplex = 0x0001;
  const typeString = 0x03;
  final flags = data.getUint8(chunkStart + 9);
  final entryCount = data.getUint32(chunkStart + 12, Endian.little);
  final entriesStart = data.getUint32(chunkStart + 16, Endian.little);
  final offsetsStart = chunkStart + headerSize;
  final isSparse = (flags & flagSparse) != 0;

  final entryOffsets = <int>[];
  for (var i = 0; i < entryCount; i++) {
    final position = offsetsStart + i * 4;
    if (position + 4 > chunkStart + chunkSize) break;
    if (isSparse) {
      final entryOffset = data.getUint16(position + 2, Endian.little) * 4;
      entryOffsets.add(entryOffset);
    } else {
      entryOffsets.add(data.getUint32(position, Endian.little));
    }
  }
  for (final entryOffset in entryOffsets) {
    if (entryOffset == 0xFFFFFFFF) continue;
    final entry = chunkStart + entriesStart + entryOffset;
    if (entry + 16 > data.lengthInBytes) continue;
    final entryFlags = data.getUint16(entry + 2, Endian.little);
    if ((entryFlags & entryFlagComplex) != 0) continue;
    final keyIndex = data.getUint32(entry + 4, Endian.little);
    final valueType = data.getUint8(entry + 8 + 3);
    if (valueType != typeString) continue;
    final stringIndex = data.getUint32(entry + 8 + 4, Endian.little);
    if (keyIndex >= keyStrings.length || stringIndex >= globalStrings.length) continue;
    result.putIfAbsent(keyStrings[keyIndex], () => globalStrings[stringIndex]);
  }
}

List<String> _readStringPool(ByteData data, Uint8List bytes, int poolStart) {
  const utf8Flag = 0x100;
  final headerSize = data.getUint16(poolStart + 2, Endian.little);
  final stringCount = data.getUint32(poolStart + 8, Endian.little);
  final flags = data.getUint32(poolStart + 16, Endian.little);
  final stringsStart = data.getUint32(poolStart + 20, Endian.little);
  final isUtf8 = (flags & utf8Flag) != 0;
  final strings = <String>[];
  for (var i = 0; i < stringCount; i++) {
    final offset = data.getUint32(poolStart + headerSize + i * 4, Endian.little);
    var position = poolStart + stringsStart + offset;
    if (position >= bytes.length) {
      strings.add('');
      continue;
    }
    if (isUtf8) {
      // Two lengths: UTF-16 character count, then byte count; each 1 or 2 bytes.
      var charLength = data.getUint8(position);
      position += (charLength & 0x80) != 0 ? 2 : 1;
      var byteLength = data.getUint8(position);
      if ((byteLength & 0x80) != 0) {
        byteLength = ((byteLength & 0x7f) << 8) | data.getUint8(position + 1);
        position += 2;
      } else {
        position += 1;
      }
      final end = position + byteLength;
      strings.add(utf8.decode(bytes.sublist(position, end > bytes.length ? bytes.length : end),
          allowMalformed: true));
    } else {
      var length = data.getUint16(position, Endian.little);
      position += 2;
      if ((length & 0x8000) != 0) {
        length = ((length & 0x7fff) << 16) | data.getUint16(position, Endian.little);
        position += 2;
      }
      final units = <int>[];
      for (var j = 0; j < length && position + 1 < bytes.length; j++) {
        units.add(data.getUint16(position, Endian.little));
        position += 2;
      }
      strings.add(String.fromCharCodes(units));
    }
  }
  return strings;
}

/// Firebase configuration found inside an APK.
class ApkFirebaseConfig {
  ApkFirebaseConfig({this.resources, this.googleServicesJson, this.assetPath});

  /// The `google_*` string resources written by the Google Services Gradle
  /// plugin, when present.
  final Map<String, String>? resources;

  /// The contents of a bundled `google-services.json` asset, when present.
  final String? googleServicesJson;

  /// The zip path of that asset.
  final String? assetPath;
}

/// Looks inside the APK at [path] for Firebase configuration: string resources
/// from the Google Services Gradle plugin, then a `google-services.json`
/// bundled as an asset.
ApkFirebaseConfig? readApkFirebaseConfig(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  ZipReader? zip;
  try {
    zip = ZipReader.open(file);
    Map<String, String>? resources;
    final arsc = zip.find('resources.arsc');
    if (arsc != null) {
      try {
        final strings = parseArscStrings(zip.read(arsc));
        if (strings.containsKey('project_id') && strings.containsKey('google_api_key')) {
          resources = strings;
        }
      } on FormatException {
        resources = null;
      }
    }
    String? json;
    String? assetPath;
    for (final entry in zip.entries) {
      if (entry.name.startsWith('assets/') && entry.name.endsWith('google-services.json')) {
        json = utf8.decode(zip.read(entry), allowMalformed: true);
        assetPath = entry.name;
        break;
      }
    }
    if (resources == null && json == null) return null;
    return ApkFirebaseConfig(
        resources: resources, googleServicesJson: json, assetPath: assetPath);
  } on FormatException {
    return null;
  } on FileSystemException {
    return null;
  } finally {
    zip?.close();
  }
}
