import 'package:firebase_core/firebase_core.dart';

/// Qyriptalk Firebase projesi (qyriptalk-cdf56).
///
/// Android uygulama kimliği (FCM push için) derleme sırasında
/// `--dart-define=FIREBASE_ANDROID_APP_ID=1:710550099549:android:xxxx`
/// ile verilebilir. Verilmezse web uygulama kimliği kullanılır: veritabanı
/// her durumda çalışır, sadece uygulama kapalıyken gelen FCM push devre dışı kalır.
class FirebaseConfig {
  static const String databaseUrl =
      'https://qyriptalk-cdf56-default-rtdb.europe-west1.firebasedatabase.app';

  static const String _androidAppId =
      String.fromEnvironment('FIREBASE_ANDROID_APP_ID', defaultValue: '');

  static const String _webAppId = '1:710550099549:web:30795fe709cca2b9fa5fb4';

  static bool get hasAndroidAppId => _androidAppId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
        apiKey: 'AIzaSyCdR7G4TXNyb2wM_OWGJYgpZrgBl8FaWqo',
        appId: hasAndroidAppId ? _androidAppId : _webAppId,
        messagingSenderId: '710550099549',
        projectId: 'qyriptalk-cdf56',
        databaseURL: databaseUrl,
        storageBucket: 'qyriptalk-cdf56.firebasestorage.app',
      );
}
