import 'package:flutter_test/flutter_test.dart';
import 'package:neo_vap/neo_vap.dart';
import 'package:neo_vap/neo_vap_platform_interface.dart';
import 'package:neo_vap/neo_vap_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockNeoVapPlatform
    with MockPlatformInterfaceMixin
    implements NeoVapPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final NeoVapPlatform initialPlatform = NeoVapPlatform.instance;

  test('$MethodChannelNeoVap is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelNeoVap>());
  });

  test('getPlatformVersion', () async {
    NeoVap neoVapPlugin = NeoVap();
    MockNeoVapPlatform fakePlatform = MockNeoVapPlatform();
    NeoVapPlatform.instance = fakePlatform;

    expect(await neoVapPlugin.getPlatformVersion(), '42');
  });
}
