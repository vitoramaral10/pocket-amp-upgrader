// SPDX-License-Identifier: GPL-3.0-only
//
// Reader for M-VAVE `.fwsc` firmware packages (JieLi UFW with an interleaved
// product name). The checks mirror `inspectPackage()` from the FM1 Open
// browser updater (m-vave/fm1_open, sdk/WebUpdate.js).

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// SHA-256 of the `ota.bin` loader shipped in every known Pocket AMP package
/// (and in the FM-1 V15 package). A package with any other loader is refused:
/// the loader is what talks to the flash, and only this one has been seen
/// working with this tool.
const String knownLoaderSha256 =
    'ef1f2db89b011fa53e71df363f0122de0ea896618c53fb53e8da676322004541';

/// Product prefixes this tool agrees to flash.
const List<String> supportedProducts = <String>['Pocket AMP'];

class FirmwareFormatException implements Exception {
  const FirmwareFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

class FirmwareEntry {
  const FirmwareEntry({
    required this.type,
    required this.name,
    required this.offset,
    required this.size,
    required this.data,
  });

  final int type;
  final String name;
  final int offset;
  final int size;
  final Uint8List data;
}

class FirmwarePackage {
  FirmwarePackage._({
    required this.product,
    required this.image,
    required this.entries,
    required this.sha256,
    required this.loaderSha256,
  });

  /// Parses and validates [raw]. Throws [FirmwareFormatException].
  factory FirmwarePackage.parse(Uint8List raw) {
    if (raw.length < 1024 || raw.length > 2 * 1024 * 1024) {
      throw const FirmwareFormatException('Invalid package size.');
    }
    // The first 960 bytes carry one product-name byte after every 47 bytes of
    // image; 125 marks the end of the name.
    final BytesBuilder image = BytesBuilder(copy: false);
    final StringBuffer product = StringBuffer();
    bool ended = false;
    for (int i = 0; i < 20; i++) {
      image.add(Uint8List.sublistView(raw, i * 48, i * 48 + 47));
      final int marker = raw[i * 48 + 47];
      if (marker == 125) {
        ended = true;
      } else {
        final int c = (marker - i - 1) & 0xFF;
        if (ended || c < 32 || c > 126) {
          throw const FirmwareFormatException('Invalid product name.');
        }
        product.writeCharCode(c);
      }
    }
    image.add(Uint8List.sublistView(raw, 960));
    final Uint8List img = image.takeBytes();

    final Uint8List head = ufwDecode(Uint8List.sublistView(img, 0, 64));
    final int count = _le(head, 8, 2);
    if (_le(head, 0, 2) != crc16(Uint8List.sublistView(head, 2)) ||
        _le(head, 4, 4) != img.length) {
      throw const FirmwareFormatException('Package header does not match.');
    }
    if (_asciiZ(Uint8List.sublistView(head, 16, 32)) != 'AC791N' ||
        count <= 0 ||
        count > 12) {
      throw const FirmwareFormatException('Unsupported chip or directory.');
    }
    final Uint8List table = Uint8List.sublistView(img, 64, 64 + count * 80);
    if (crc16(table) != _le(head, 2, 2)) {
      throw const FirmwareFormatException('Package directory is corrupt.');
    }

    final List<FirmwareEntry> entries = <FirmwareEntry>[];
    for (int i = 0; i < count; i++) {
      final Uint8List e = ufwDecode(
        Uint8List.sublistView(table, i * 80, i * 80 + 80),
      );
      final int type = _le(e, 0, 2);
      final int offset = _le(e, 8, 4);
      final int size = _le(e, 12, 4);
      final int encrypted = _le(e, 24, 4);
      final String name = _asciiZ(Uint8List.sublistView(e, 64));
      if (offset < 64 + count * 80 || offset + size > img.length) {
        throw FirmwareFormatException('Entry outside the package: $name');
      }
      final Uint8List data = Uint8List.sublistView(img, offset, offset + size);
      if (encrypted == 0 && crc16(data) != _le(e, 4, 2)) {
        throw FirmwareFormatException('CRC mismatch: $name');
      }
      entries.add(
        FirmwareEntry(
          type: type,
          name: name,
          offset: offset,
          size: size,
          data: data,
        ),
      );
    }

    final List<FirmwareEntry> flash = entries
        .where((FirmwareEntry e) => e.type == 0)
        .toList();
    final List<FirmwareEntry> loader = entries
        .where((FirmwareEntry e) => e.type == 100)
        .toList();
    if (flash.length != 1 ||
        flash.single.size % 4096 != 0 ||
        flash.single.size < 16384 ||
        flash.single.size > 1044480) {
      throw const FirmwareFormatException('Invalid flash image.');
    }
    if (loader.length != 1 ||
        loader.single.size <= 0 ||
        loader.single.size >= 32768) {
      throw const FirmwareFormatException('Missing or invalid loader.');
    }

    return FirmwarePackage._(
      product: product.toString(),
      image: img,
      entries: List<FirmwareEntry>.unmodifiable(entries),
      sha256: crypto.sha256.convert(raw).toString(),
      loaderSha256: crypto.sha256.convert(loader.single.data).toString(),
    );
  }

  /// Product identity, e.g. `Pocket AMP_105`.
  final String product;

  /// Package with the product bytes removed: what the pedal reads from.
  final Uint8List image;
  final List<FirmwareEntry> entries;
  final String sha256;
  final String loaderSha256;

  /// `Pocket AMP` for `Pocket AMP_105`.
  String get productFamily => familyOf(product);

  /// `1.05` for `Pocket AMP_105`, or the raw suffix if it is not numeric.
  String get version => versionOf(product);

  bool get hasKnownLoader => loaderSha256 == knownLoaderSha256;

  bool get isSupportedProduct => supportedProducts.contains(productFamily);
}

/// `Pocket AMP` for `Pocket AMP_105` or `ota-Pocket AMP_103`.
String familyOf(String identity) {
  final String id = identity.startsWith('ota-')
      ? identity.substring(4)
      : identity;
  final int cut = id.lastIndexOf('_');
  return cut < 0 ? id : id.substring(0, cut);
}

/// `1.05` for `Pocket AMP_105`.
String versionOf(String identity) {
  final int cut = identity.lastIndexOf('_');
  if (cut < 0) {
    return '?';
  }
  final String v = identity.substring(cut + 1);
  if (RegExp(r'^\d{3}$').hasMatch(v)) {
    return '${v[0]}.${v.substring(1)}';
  }
  return v;
}

/// CRC-16/XMODEM (poly 0x1021, init 0).
int crc16(List<int> data) {
  int c = 0;
  for (final int b in data) {
    c ^= b << 8;
    for (int i = 0; i < 8; i++) {
      c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x1021) & 0xFFFF : (c << 1) & 0xFFFF;
    }
  }
  return c;
}

/// JieLi UFW header cipher: XOR with a CRC-16 shift register.
Uint8List ufwDecode(List<int> data, [int key = 0xFFFF]) {
  final Uint8List out = Uint8List.fromList(data);
  int k = key;
  for (int i = 0; i < out.length; i++) {
    out[i] ^= k & 0xFF;
    k = ((k << 1) ^ ((k & 0x8000) != 0 ? 0x1021 : 0)) & 0xFFFF;
  }
  return out;
}

int _le(List<int> b, int at, int n) {
  int v = 0;
  for (int i = n - 1; i >= 0; i--) {
    v = (v << 8) | b[at + i];
  }
  return v;
}

String _asciiZ(List<int> b) {
  final int end = b.indexOf(0);
  return latin1.decode(end < 0 ? b : b.sublist(0, end));
}
