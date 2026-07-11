import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/neo_vap.dart';

/// Build a minimal mp4 box `[uint32 size][4-char type][payload]`.
Uint8List _box(String type, List<int> payload) {
  final size = 8 + payload.length;
  final b = BytesBuilder();
  b.add([
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
  ]);
  b.add(ascii.encode(type));
  b.add(payload);
  return b.toBytes();
}

Uint8List _mp4({required String vapcJson, bool includeVapc = true}) {
  final b = BytesBuilder();
  b.add(_box('ftyp', ascii.encode('isom')));
  if (includeVapc) b.add(_box('vapc', utf8.encode(vapcJson)));
  b.add(_box('mdat', const [0, 0, 0, 0]));
  return b.toBytes();
}

/// mp4 with a 64-bit-largesize `vapc` box (size field == 1).
Uint8List _mp4Largesize(String vapcJson) {
  final payload = utf8.encode(vapcJson);
  final b = BytesBuilder();
  b.add(_box('ftyp', ascii.encode('isom')));
  b.add(const [0, 0, 0, 1]); // size == 1 -> 64-bit largesize follows type
  b.add(ascii.encode('vapc'));
  b.add((ByteData(8)..setUint64(0, 16 + payload.length)).buffer.asUint8List());
  b.add(payload);
  b.add(_box('mdat', const [0, 0, 0, 0]));
  return b.toBytes();
}

/// mp4 whose final `vapc` box uses size == 0 ("extends to end of file").
Uint8List _mp4Size0(String vapcJson) {
  final b = BytesBuilder();
  b.add(_box('ftyp', ascii.encode('isom')));
  b.add(const [0, 0, 0, 0]); // size == 0 -> to EOF; must be the last box
  b.add(ascii.encode('vapc'));
  b.add(utf8.encode(vapcJson));
  return b.toBytes();
}

void main() {
  // Exact info payload extracted from the real
  // active_mode_intro_vap.mp4 vapc atom.
  const realJson =
      '{"info":{"v":2,"f":49,"w":1000,"h":1000,"fps":25,"videoW":1504,'
      '"videoH":1008,"aFrame":[1004,0,500,500],"rgbFrame":[0,0,1000,1000],'
      '"isVapx":0,"orien":0}}';

  group('VapcInfo.parse (real asset atom)', () {
    late VapcInfo info;
    setUp(() => info = VapcInfo.parse(_mp4(vapcJson: realJson)));

    test('parses frame/dimension metadata', () {
      expect(info.version, 2);
      expect(info.frameCount, 49);
      expect(info.width, 1000);
      expect(info.height, 1000);
      expect(info.fps, 25);
      expect(info.videoWidth, 1504);
      expect(info.videoHeight, 1008);
      expect(info.isVapx, false);
      expect(info.orientation, 0);
    });

    test('parses rgbFrame and aFrame regions (KTD-2)', () {
      expect(info.rgbFrame, const VapcRect(0, 0, 1000, 1000));
      expect(info.aFrame, const VapcRect(1004, 0, 500, 500));
    });

    test('derives square aspect and half alpha scale', () {
      expect(info.aspectRatio, 1.0);
      expect(info.alphaScale, 0.5); // alpha stored at 500 vs rgb 1000
    });
  });

  test('parses gunmetal 16:9 content aspect', () {
    // gunmetal is 1504x846 content per the plan.
    const gunmetal =
        '{"info":{"v":2,"f":60,"w":1504,"h":846,"fps":25,"videoW":1504,'
        '"videoH":1269,"aFrame":[0,846,752,423],"rgbFrame":[0,0,1504,846],'
        '"isVapx":0,"orien":0}}';
    final info = VapcInfo.parse(_mp4(vapcJson: gunmetal));
    expect(info.aspectRatio, closeTo(1504 / 846, 1e-9));
    expect(info.rgbFrame.w, 1504);
  });

  group('box-format variants', () {
    const json =
        '{"info":{"v":2,"f":10,"w":100,"h":100,"fps":25,"videoW":200,'
        '"videoH":100,"aFrame":[100,0,100,100],"rgbFrame":[0,0,100,100],'
        '"isVapx":0,"orien":0}}';

    test('parses a 64-bit largesize vapc box', () {
      final info = VapcInfo.parse(_mp4Largesize(json));
      expect(info.width, 100);
      expect(info.rgbFrame, const VapcRect(0, 0, 100, 100));
    });

    test('parses a size==0 (to-EOF) vapc box', () {
      final info = VapcInfo.parse(_mp4Size0(json));
      expect(info.frameCount, 10);
      expect(info.aFrame, const VapcRect(100, 0, 100, 100));
    });
  });

  test('aspectRatio and alphaScale guard divide-by-zero', () {
    const zero =
        '{"info":{"v":2,"f":1,"w":0,"h":0,"fps":25,"videoW":0,"videoH":0,'
        '"aFrame":[0,0,0,0],"rgbFrame":[0,0,0,0],"isVapx":0,"orien":0}}';
    final info = VapcInfo.parse(_mp4(vapcJson: zero));
    expect(info.aspectRatio, 1.0); // height == 0 guard
    expect(info.alphaScale, 1.0); // rgbFrame.w == 0 guard
  });

  group('error handling', () {
    test('throws when no vapc atom present', () {
      expect(
        () => VapcInfo.parse(_mp4(vapcJson: '', includeVapc: false)),
        throwsA(isA<VapcParseException>()),
      );
    });

    test('throws on vapc atom without info object', () {
      expect(
        () => VapcInfo.parse(_mp4(vapcJson: '{"nope":1}')),
        throwsA(isA<VapcParseException>()),
      );
    });

    test('wraps non-JSON vapc payload as VapcParseException', () {
      expect(
        () => VapcInfo.parse(_mp4(vapcJson: 'not json')),
        throwsA(isA<VapcParseException>()),
      );
    });
  });
}
