import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/neo_vap.dart';

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
}
