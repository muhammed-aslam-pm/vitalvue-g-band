import 'package:flutter_test/flutter_test.dart';
import 'package:veepoo_sdk/veepoo_sdk.dart';
import 'package:veepoo_sdk/veepoo_sdk_platform_interface.dart';
import 'package:veepoo_sdk/veepoo_sdk_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockVeepooSdkPlatform
    with MockPlatformInterfaceMixin
    implements VeepooSdkPlatform {
  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final VeepooSdkPlatform initialPlatform = VeepooSdkPlatform.instance;

  test('$MethodChannelVeepooSdk is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelVeepooSdk>());
  });

  test('getPlatformVersion', () async {
    VeepooSdk veepooSdkPlugin = VeepooSdk();
    MockVeepooSdkPlatform fakePlatform = MockVeepooSdkPlatform();
    VeepooSdkPlatform.instance = fakePlatform;

    expect(await veepooSdkPlugin.getPlatformVersion(), '42');
  });
}
