import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'veepoo_sdk_method_channel.dart';

abstract class VeepooSdkPlatform extends PlatformInterface {
  /// Constructs a VeepooSdkPlatform.
  VeepooSdkPlatform() : super(token: _token);

  static final Object _token = Object();

  static VeepooSdkPlatform _instance = MethodChannelVeepooSdk();

  /// The default instance of [VeepooSdkPlatform] to use.
  ///
  /// Defaults to [MethodChannelVeepooSdk].
  static VeepooSdkPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [VeepooSdkPlatform] when
  /// they register themselves.
  static set instance(VeepooSdkPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
