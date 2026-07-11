import 'dart:convert';
import 'dart:typed_data';

/// An integer pixel rectangle `[x, y, w, h]` as stored in a `vapc` atom.
///
/// VAP packs the colour and alpha halves of a frame at fixed positions inside
/// the (opaque) video frame; the shader crops these regions. Kept as plain ints
/// so this file stays pure Dart (no Flutter dependency) and trivially testable.
class VapcRect {
  const VapcRect(this.x, this.y, this.w, this.h);

  final int x;
  final int y;
  final int w;
  final int h;

  factory VapcRect.fromList(List<dynamic> l) {
    if (l.length < 4) {
      throw const VapcParseException('rect needs 4 elements [x,y,w,h]');
    }
    return VapcRect(
      (l[0] as num).toInt(),
      (l[1] as num).toInt(),
      (l[2] as num).toInt(),
      (l[3] as num).toInt(),
    );
  }

  @override
  String toString() => 'VapcRect($x, $y, $w, $h)';

  @override
  bool operator ==(Object other) =>
      other is VapcRect &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h;

  @override
  int get hashCode => Object.hash(x, y, w, h);
}

/// Parsed contents of a VAP `vapc` atom's `info` object.
///
/// Drives the alpha-composite shader (rgb/alpha crop regions) and the widget's
/// content aspect ratio.
class VapcInfo {
  const VapcInfo({
    required this.version,
    required this.frameCount,
    required this.width,
    required this.height,
    required this.fps,
    required this.videoWidth,
    required this.videoHeight,
    required this.rgbFrame,
    required this.aFrame,
    required this.isVapx,
    required this.orientation,
  });

  /// vapc format version (`v`).
  final int version;

  /// Number of frames (`f`); matches the video's `nb_frames`.
  final int frameCount;

  /// Content (composited output) width (`w`).
  final int width;

  /// Content (composited output) height (`h`).
  final int height;

  final int fps;

  /// Actual decoded video frame width (`videoW`), i.e. rgb-half + alpha-half.
  final int videoWidth;

  /// Actual decoded video frame height (`videoH`).
  final int videoHeight;

  /// Colour region within the video frame.
  final VapcRect rgbFrame;

  /// Alpha region within the video frame (often stored at [alphaScale]).
  final VapcRect aFrame;

  /// Whether this is a VAPX asset (dynamic text/image sources). 0 for our clips.
  final bool isVapx;

  /// Orientation flag (`orien`); 0 for our clips.
  final int orientation;

  /// Content aspect ratio (width / height), for laying out the [Texture].
  double get aspectRatio => height == 0 ? 1.0 : width / height;

  /// Ratio of the alpha region's size to the colour region's size. VAP commonly
  /// stores alpha at half resolution (0.5); the shader upsamples it.
  double get alphaScale => rgbFrame.w == 0 ? 1.0 : aFrame.w / rgbFrame.w;

  /// Parse the `vapc` atom out of a full VAP mp4's [bytes].
  ///
  /// Walks top-level mp4 boxes looking for the `vapc` box (a JSON payload).
  /// Throws [VapcParseException] if the box is missing or malformed.
  static VapcInfo parse(Uint8List bytes) {
    try {
      final json = _extractVapcJson(bytes);
      final dynamic decoded = jsonDecode(json);
      if (decoded is! Map || decoded['info'] is! Map) {
        throw const VapcParseException('vapc atom missing "info" object');
      }
      final info = decoded['info'] as Map;
      return VapcInfo(
        version: (info['v'] as num).toInt(),
        frameCount: (info['f'] as num).toInt(),
        width: (info['w'] as num).toInt(),
        height: (info['h'] as num).toInt(),
        fps: (info['fps'] as num).toInt(),
        videoWidth: (info['videoW'] as num).toInt(),
        videoHeight: (info['videoH'] as num).toInt(),
        rgbFrame: VapcRect.fromList(info['rgbFrame'] as List),
        aFrame: VapcRect.fromList(info['aFrame'] as List),
        isVapx: ((info['isVapx'] as num?)?.toInt() ?? 0) != 0,
        orientation: (info['orien'] as num?)?.toInt() ?? 0,
      );
    } on VapcParseException {
      rethrow;
    } catch (e) {
      // Wrap FormatException (bad UTF-8 / non-JSON) and field type errors so
      // callers only ever have to catch VapcParseException.
      throw VapcParseException('malformed vapc atom: $e');
    }
  }

  /// Find the top-level `vapc` box and return its UTF-8 JSON payload.
  ///
  /// mp4 box = `[uint32 size][4-char type][payload]`; size==1 means a 64-bit
  /// largesize follows the type, size==0 means "to end of file".
  static String _extractVapcJson(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    int offset = 0;
    while (offset + 8 <= bytes.length) {
      int size = data.getUint32(offset);
      int headerSize = 8;
      if (size == 1) {
        if (offset + 16 > bytes.length) break;
        size = data.getUint64(offset + 8);
        headerSize = 16;
      } else if (size == 0) {
        size = bytes.length - offset; // extends to EOF
      }
      if (size < headerSize || offset + size > bytes.length) {
        throw VapcParseException('corrupt mp4 box at offset $offset (size $size)');
      }
      final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
      if (type == 'vapc') {
        final payload = Uint8List.sublistView(
          bytes,
          offset + headerSize,
          offset + size,
        );
        // Trailing NULs sometimes pad the box; trim before decoding.
        return utf8.decode(payload).replaceAll('\x00', '').trim();
      }
      offset += size;
    }
    throw const VapcParseException('no vapc atom found (not a VAP mp4?)');
  }

  @override
  String toString() =>
      'VapcInfo(v$version, ${frameCount}f, ${width}x$height @${fps}fps, '
      'video ${videoWidth}x$videoHeight, rgb $rgbFrame, a $aFrame, '
      'alphaScale $alphaScale, vapx $isVapx)';
}

/// Thrown when a buffer is not a valid VAP mp4 or its `vapc` atom is malformed.
class VapcParseException implements Exception {
  const VapcParseException(this.message);
  final String message;
  @override
  String toString() => 'VapcParseException: $message';
}
