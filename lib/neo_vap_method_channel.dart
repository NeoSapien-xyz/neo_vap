import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'neo_vap_platform_interface.dart';

/// An implementation of [NeoVapPlatform] that uses method channels.
class MethodChannelNeoVap extends NeoVapPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('neo_vap');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
