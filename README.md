# Qyriptalk — Flutter

Qyriptalk'ın baştan yazılmış, yerel (native) Flutter sürümü. Eski WebView uygulamasıyla **aynı Firebase
veritabanını** (`qyriptalk-cdf56`) kullanır: hesaplar, odalar, özel mesajlar ve aramalar iki sürüm arasında
ortaktır. Web sürümünden yazan biriyle Flutter sürümünden konuşabilirsin.

## Özellikler

**Sohbet**
- Özel mesajlar (DM) ve odalar tek listede; sabitleme, sessize alma, arşivleme, okunmamış sayacı
- Filtreler: Tümü / Okunmamış / Kişiler / Odalar, sohbet içi arama
- Messenger tarzı gradyan baloncuklar, gruplanmış mesajlar, gün ayraçları
- Yanıtla (kaydırarak ya da menüden), düzenle, herkesten sil, sabitle, ilet, kopyala, çoklu seçim
- **Tepkiler** (❤️ 😂 😮 😢 🙏 👍 🔥), çift dokunuşla ❤️
- Okundu bilgisi (✓✓), "yazıyor…" göstergesi (odalarda **ve** özel sohbetlerde), çevrimiçi / son görülme
- Fotoğraf, kamera, video, dosya ve **sesli mesaj** (dalga formu, 1x / 1.5x / 2x hız)
- Mesaj çevirisi (TR ⇄ EN) ve isteğe bağlı otomatik çeviri, tıklanabilir bağlantılar, emoji paneli

**Odalar**
- Keşfet listesi (herkese açık odalar), şifreli ve gizli odalar
- Davet bağlantısı + **QR kod**, paylaş
- Oda bilgisi: üyeler, kurucu rozeti, çıkarma / yasaklama / yasağı kaldırma, ad / logo / açıklama / şifre düzenleme

**Sesli arama**
- WebRTC; web sürümüyle birebir uyumlu sinyalleşme (DM ve grup araması)
- Tam ekran gelen arama, kilit ekranında Cevapla / Reddet, hoparlör, sessiz, süre sayacı
- Arama geçmişi (gelen / giden / cevapsız), geri arama

**Bildirimler**
- Uygulama açıkken / arka plandayken anlık mesaj bildirimleri, Qyriptalk bildirim sesi
- Kilit ekranında içerik göster/gizle, sessiz kanal, gelen mesajları sesli okuma
- FCM ile uygulama tamamen kapalıyken de bildirim (aşağıdaki kurulum)

**Genel**
- Açık / koyu / sistem teması, sıkı görünüm, Türkçe arayüz
- Çevrimdışı önbellek (Firebase kalıcılığı) ve bağlantı uyarısı

## Derleme

GitHub Actions her `main` push'unda APK'yı derler ve **Releases**'a yükler:

`https://github.com/<kullanıcı>/qyriptalk-flutter/releases/latest/download/Qyriptalk.apk`

Yerelde:

```bash
flutter create --platforms=android --org com.xadan --project-name qyriptalk .
python3 ci/patch_android.py
flutter pub get
flutter build apk --release
```

## İsteğe bağlı ayarlar (GitHub → Settings → Secrets → Actions)

| Secret | Ne işe yarar |
|---|---|
| `FIREBASE_ANDROID_APP_ID` | Firebase konsolunda `com.xadan.qyriptalk` Android uygulamasının kimliği (`1:710550099549:android:...`). Verilirse FCM push açılır: uygulama tamamen kapalıyken de bildirim gelir. Sunucu tarafı (Cloud Functions) eski repodaki `functions/` ile aynıdır. |
| `QT_KEYSTORE_B64`, `QT_KEYSTORE_PASSWORD` (`QT_KEY_ALIAS`, `QT_KEY_PASSWORD`) | Eski Qyriptalk repo'sundaki imza anahtarının aynısı. Eklenirse yeni sürüm eskisinin **üzerine** kurulur. Eklenmezse, eski uygulamayı kaldırıp yenisini kurman gerekir (paket adı aynı: `com.xadan.qyriptalk`). |

## Güvenlik notu

Uyumluluk için hesap sistemi eski sürümle aynı kaldı (kullanıcı adı + şifre veritabanında). Bir sonraki adım
olarak Firebase Authentication'a geçiş ve veritabanı kurallarının sıkılaştırılması önerilir.
