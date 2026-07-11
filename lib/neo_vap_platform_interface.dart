import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'neo_vap_method_channel.dart';

abstract class NeoVapPlatform extends PlatformInterface {
  /// Constructs a NeoVapPlatform.
  NeoVapPlatform() : super(token: _token);

  static final Object _token = Object();

  static NeoVapPlatform _instance = MethodChannelNeoVap();

  /// The default instance of [NeoVapPlatform] to use.
  ///
  /// Defaults to [MethodChannelNeoVap].
  static NeoVapPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [NeoVapPlatform] when
  /// they register themselves.
  static set instance(NeoVapPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
