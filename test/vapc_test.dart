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

    test('throws on non-JSON vapc payload', () {
      expect(
        () => VapcInfo.parse(_mp4(vapcJson: 'not json')),
        throwsA(anything),
      );
    });
  });
}
