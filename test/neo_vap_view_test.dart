import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/neo_vap.dart';
import 'package:neo_vap/src/neo_vap_method_channel.dart';

import 'neo_vap_controller_test.dart' show FakeBackend;

void main() {
  Widget wrap(Widget child) =>
      Directionality(textDirection: TextDirection.ltr, child: child);

  testWidgets('renders a Texture once the backend allocates one',
      (tester) async {
    final backend = FakeBackend();
    final controller = NeoVapController(videoAsset: 'loop.mp4', backend: backend);

    await tester.pumpWidget(
      wrap(NeoVapView(videoAsset: 'loop.mp4', controller: controller)),
    );
    await tester.pump(); // flush initialize()/play()

    expect(find.byType(Texture), findsOneWidget);
    expect(controller.textureId, 42);

    controller.dispose();
    await backend.close();
  });

  testWidgets('placeholder fades out on the first frame', (tester) async {
    final backend = FakeBackend();
    final controller = NeoVapController(videoAsset: 'loop.mp4', backend: backend);

    await tester.pumpWidget(
      wrap(NeoVapView(
        videoAsset: 'loop.mp4',
        placeholderAsset: 'placeholder.png',
        controller: controller,
      )),
    );
    await tester.pump();
    tester.takeException(); // ignore missing-asset load (no bundle in tests)

    AnimatedOpacity opacity() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity().opacity, 1.0);

    backend.emit(NeoVapEvent(controller.textureId!, NeoVapEventType.firstFrame));
    await tester.idle(); // deliver the broadcast stream event to the controller
    await tester.pump(); // rebuild with the new opacity target
    expect(opacity().opacity, 0.0);

    controller.dispose();
    await backend.close();
  });

  testWidgets('portrait aspect does not produce a sub-pixel texture box',
      (tester) async {
    // Regression: the aspect box used to be SizedBox(width: ar, height: 1). For
    // a portrait clip (ar < 1) Impeller's GLES path casts the layout width to
    // int, gets 0, and discards every frame — the texture renders as nothing.
    // Any non-degenerate box with the same ratio is fine; what must never come
    // back is a dimension that truncates to zero.
    final backend = FakeBackend();
    final controller = NeoVapController(videoAsset: 'loop.mp4', backend: backend);

    await tester.pumpWidget(
      wrap(NeoVapView(videoAsset: 'loop.mp4', controller: controller)),
    );
    await tester.pump();

    // 710x1134 pendant geometry -> ar ~= 0.626, the case that broke.
    backend.emit(const NeoVapEvent(42, NeoVapEventType.info,
        width: 710, height: 1134));
    await tester.pump(); // stream delivery -> notifyListeners
    await tester.pump(); // rebuild with the new aspect

    final box = tester.getSize(find.byType(Texture));
    expect(box.width.floor(), greaterThan(0));
    expect(box.height.floor(), greaterThan(0));
    expect(box.width / box.height, closeTo(710 / 1134, 1e-6));

    controller.dispose();
    await backend.close();
  });
}
