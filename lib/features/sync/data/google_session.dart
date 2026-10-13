import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../domain/sync_engine.dart';

class SyncUser {
  const SyncUser({required this.uid, this.name, this.email, this.photoUrl});
  final String uid;
  final String? name, email, photoUrl;
}

abstract interface class SyncAuth {
  Future<void> initialize();
  SyncUser? get currentUser;
  Future<SyncUser?> signIn();
  Future<void> signOut();
}

class GoogleSession implements SyncAuth {
  Future<void>? _initializing;
  FirebaseAuth get auth => FirebaseAuth.instance;

  @override
  Future<void> initialize() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
      throw const SyncFailure(
        'Đăng nhập Google chỉ được cấu hình trong bản iOS của TachiBooks.',
      );
    }
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      await GoogleSignIn.instance.initialize();
    } catch (_) {
      throw const SyncFailure(
        'Bản iOS này chưa có cấu hình Firebase và Google hợp lệ cho TachiBooks. Thư viện trên máy vẫn dùng được.',
      );
    }
  }

  SyncUser? _user(User? user) => user == null
      ? null
      : SyncUser(
          uid: user.uid,
          name: user.displayName,
          email: user.email,
          photoUrl: user.photoURL,
        );
  @override
  SyncUser? get currentUser =>
      Firebase.apps.isEmpty ? null : _user(auth.currentUser);

  @override
  Future<SyncUser?> signIn() async {
    await initialize();
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw const SyncFailure(
        'Không thể mở đăng nhập Google trên thiết bị này.',
      );
    }
    try {
      final google = await GoogleSignIn.instance.authenticate();
      final token = google.authentication.idToken;
      if (token == null) {
        throw const SyncFailure(
          'Google chưa trả về thông tin đăng nhập. Hãy thử lại.',
        );
      }
      final result = await auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: token),
      );
      return _user(result.user);
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  @override
  Future<void> signOut() async {
    if (Firebase.apps.isNotEmpty) await auth.signOut();
    await GoogleSignIn.instance.signOut();
  }
}

/// Provider errors can contain identifiers or tokens; show mapped messages only.
String syncErrorMessage(Object error) {
  if (error is SyncFailure) return error.message;
  if (error is FormatException) {
    return 'Bản sao lưu không hợp lệ. Dữ liệu trên máy được giữ nguyên.';
  }
  if (error is GoogleSignInException) {
    return switch (error.code) {
      GoogleSignInExceptionCode.clientConfigurationError ||
      GoogleSignInExceptionCode.providerConfigurationError => 'Cấu hình đăng nhập Google chưa hợp lệ. Cần cấu hình Firebase iOS riêng cho TachiBooks.',
      _ => 'Không thể hoàn tất đăng nhập Google. Hãy thử lại.',
    };
  }
  if (error is FirebaseException) {
    return switch (error.code) {
      'network-request-failed' || 'unavailable' || 'deadline-exceeded' => 'Không kết nối được cloud. Dữ liệu trên máy được giữ nguyên; hãy đồng bộ lại khi có mạng.',
      'permission-denied' => 'Cloud từ chối truy cập dữ liệu của tài khoản. Kiểm tra quy tắc Firestore của TachiBooks đã hỗ trợ đồng bộ phiên bản 2; dữ liệu trên máy được giữ nguyên.',
      'operation-not-allowed' => 'Đăng nhập Google chưa được bật trong Firebase của TachiBooks. Bật Google trong Authentication rồi thử đăng nhập lại.',
      'resource-exhausted' => 'Đã chạm hạn mức Firebase miễn phí. Thư viện trên máy vẫn dùng được; hãy thử lại sau.',
      'invalid-credential' ||
      'user-token-expired' ||
      'requires-recent-login' ||
      'unauthenticated' => 'Phiên đăng nhập hết hạn. Hãy đăng nhập Google lại.',
      'user-disabled' => 'Tài khoản đăng nhập đã bị vô hiệu hóa.',
      _ => 'Đồng bộ chưa hoàn tất. Dữ liệu trên máy được giữ nguyên.',
    };
  }
  return 'Đồng bộ chưa hoàn tất. Dữ liệu trên máy được giữ nguyên; hãy thử lại.';
}
