import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'veepoo_sdk_platform_interface.dart';

/// An implementation of [VeepooSdkPlatform] that uses method channels.
class MethodChannelVeepooSdk extends VeepooSdkPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('veepoo_sdk');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
