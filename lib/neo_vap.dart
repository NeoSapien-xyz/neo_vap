
import 'neo_vap_platform_interface.dart';

class NeoVap {
  Future<String?> getPlatformVersion() {
    return NeoVapPlatform.instance.getPlatformVersion();
  }
}
