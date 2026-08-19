import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persistent, encrypted storage for JWT tokens.
///
/// Uses `flutter_secure_storage` which maps to:
///   Android — Android Keystore (EncryptedSharedPreferences)
///   iOS     — Keychain
class AuthTokenStore {
  AuthTokenStore() : _s = const FlutterSecureStorage();

  static const _kAccess = 'auth_access_token';
  static const _kRefresh = 'auth_refresh_token';
  static const _kUserId = 'auth_user_id';

  final FlutterSecureStorage _s;

  Future<void> save({
    required String accessToken,
    required String refreshToken,
    required String userId,
  }) async {
    await Future.wait([
      _s.write(key: _kAccess, value: accessToken),
      _s.write(key: _kRefresh, value: refreshToken),
      _s.write(key: _kUserId, value: userId),
    ]);
  }

  Future<void> saveAccessToken(String token) =>
      _s.write(key: _kAccess, value: token);

  Future<String?> get accessToken async {
    try {
      return await _s.read(key: _kAccess);
    } catch (e) {
      await _s.deleteAll();
      return null;
    }
  }

  Future<String?> get refreshToken async {
    try {
      return await _s.read(key: _kRefresh);
    } catch (e) {
      return null;
    }
  }

  Future<String?> get userId async {
    try {
      return await _s.read(key: _kUserId);
    } catch (e) {
      return null;
    }
  }

  Future<bool> get hasToken async {
    try {
      return (await _s.read(key: _kAccess)) != null;
    } catch (e) {
      await _s.deleteAll();
      return false;
    }
  }

  Future<void> clear() async {
    try {
      await Future.wait([
        _s.delete(key: _kAccess),
        _s.delete(key: _kRefresh),
        _s.delete(key: _kUserId),
      ]);
    } catch (e) {
      await _s.deleteAll();
    }
  }
}
