# Menyiapkan proyek setelah clone

Langkah dari Mac kosong sampai aplikasi jalan di HP, ditambah apa saja yang tidak ada di git
dan harus disimpan di tempat lain.

## 1. Yang tidak ada di repository

| File | Isi | Simpan di | Tanpa file ini |
|---|---|---|---|
| `config/dev.json` | URL Supabase, anon/publishable key, token Mapbox `pk.`, URL web | Password manager | Aplikasi tidak bisa dibuild (lihat `config/dev.json.example`) |
| `config/prod.json` | Sama, untuk build rilis (belum dibuat) | Password manager | Hanya build dev |
| `android/key.properties` + keystore `.jks` | Kunci upload Play Store (Fase 10, belum dibuat) | Password manager + cadangan file | APK ditandatangani kunci debug |
| `store/` | Ikon store, screenshot, feature graphic | Bisa dibuat ulang (bagian 6) | — |
| `install-guide-temporary.md` | Panduan membagikan APK / iPhone selama uji | Bisa ditulis ulang | — |

Isi `config/dev.json` **tidak bisa didapat dari repository**. Ambil dari:

- `SUPABASE_URL`, `SUPABASE_ANON_KEY`: Supabase Dashboard > Project Settings > API (kunci
  **publishable / anon**, **jangan pernah** service role; aplikasi menolak start jika diisi)
- `MAPBOX_PUBLIC_TOKEN`: akun Mapbox > Tokens (token publik `pk.…`)
- `API_BASE_URL`: `https://landscape360.jcdigital.co.id`

## 2. Perangkat lunak

| Alat | Versi yang dipakai | Pasang |
|---|---|---|
| Flutter | 3.47.8 (Dart ^3.13) | `brew install --cask flutter` |
| Xcode | 27.x, target iOS 15.0 | App Store, lalu `sudo xcodebuild -runFirstLaunch` |
| CocoaPods | terbaru | `brew install cocoapods` |
| Java | 17 atau lebih baru | `brew install --cask temurin@17` |
| Android SDK | platform terbaru + build-tools + emulator | Android Studio > SDK Manager |
| Python 3 + Pillow | hanya untuk `tool/brand`, `tool/store` | `python3 -m pip install pillow` |
| Node | hanya untuk `tool/web_reference` | `brew install node` |

Cek: `flutter doctor` tanpa tanda silang untuk Xcode dan Android.

## 3. Clone dan jalankan

```sh
git clone git@github.com:rizkybor/Landscape360M.git
cd Landscape360M
cp config/dev.json.example config/dev.json   # lalu isi (bagian 1)
flutter pub get
flutter analyze && flutter test              # harus bersih dan lulus semua
flutter run --flavor dev --dart-define-from-file=config/dev.json
```

Repo web dipakai sebagai referensi (fixture paritas, perubahan backend di `docs/backend/`).
Clone di sebelahnya bila perlu:

```sh
git clone <repo web> ../Landscape360
```

## 4. iPhone

1. Xcode > Settings > Accounts: tambah Apple ID. Catat **Team ID** (gratis: Personal Team).
2. Buka `ios/Runner.xcworkspace` sekali, Runner > Signing & Capabilities: pilih team
   (Debug dan Profile memakai bundle `id.co.jcdigital.landscape360.dev`).
3. iPhone: sambungkan kabel, buka kunci, **Percayai komputer ini**, nyalakan
   **Pengaturan > Privasi & Keamanan > Mode Pengembang**.
4. Pasang:

   ```sh
   flutter build ios --profile --dart-define-from-file=config/dev.json
   cd ios && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Profile \
     -destination id=<UDID> -allowProvisioningUpdates DEVELOPMENT_TEAM=<Team ID> build
   xcrun devicectl device install app --device <UDID> \
     ~/Library/Developer/Xcode/DerivedData/Runner-*/Build/Products/Profile-iphoneos/Runner.app
   ```

   `<UDID>`: `xcrun devicectl list devices`. Pertama kali: **Pengaturan > Umum > VPN &
   Manajemen Perangkat > Percayai**.
5. Build **Release** memakai Associated Domains (`ios/Runner/Runner.entitlements`) dan butuh
   akun Apple Developer berbayar; Personal Team hanya untuk Debug / Profile.

## 5. Android

```sh
flutter run --flavor dev --dart-define-from-file=config/dev.json            # HP lewat USB
flutter build apk --release --flavor dev --target-platform android-arm64 \
  --dart-define-from-file=config/dev.json                                    # APK untuk dibagikan
```

Emulator (untuk screenshot dan uji): Android Studio > Device Manager > Pixel dengan image
**Android 34 Google APIs arm64**, RAM minimal **3 GB** (1,5 GB membuat sistem emulator mati saat
peta 3D). Jika `sdkmanager` gagal mengunduh, image bisa diunduh langsung dari
`https://dl.google.com/android/repository/sys-img/google_apis/arm64-v8a-34_r14.zip` dan diekstrak
ke `$ANDROID_HOME/system-images/android-34/google_apis/`.

## 6. Membuat ulang aset store

```sh
python3 tool/brand/make_icons.py                       # ikon app + splash (dari tool/brand/logo_1080.png)
tool/store/screenshots.sh <UDID simulator> store/screenshots/ios-6.7       # iPhone 15 Pro Max
tool/store/screenshots.sh <UDID simulator> store/screenshots/ipad-12.9     # iPad Pro 12.9"
tool/store/screenshots_android.sh emulator-5554 store/screenshots/android-phone
python3 tool/store/frame_screenshots.py                # bingkai + judul ID/EN, feature graphic
python3 tool/store/check_listing.py                    # panjang teks docs/store/listing.md
```

UDID simulator: `xcrun simctl list devices`.

## 7. Integration test

```sh
flutter test integration_test/<file>.dart -d <simulator/HP> --dart-define-from-file=config/dev.json
```

`survey_flow_test.dart` butuh akun uji:
`--dart-define=L360_TEST_EMAIL=… --dart-define=L360_TEST_PASSWORD=…` (jangan di-commit).

## 8. Pekerjaan yang masih menunggu

- Terapkan perubahan web + Supabase: `docs/backend/live-tracking/` (kanal privat GPS
  Tracking) dan `docs/backend/store/` (hapus akun, `/delete-account`, `.well-known`,
  Privacy Policy). Sebelum diterapkan, GPS Tracking dan Delete account di app belum jalan.
- Push notification S.O.S: project Firebase + Apple Developer berbayar.
- Fase 10 (rilis): keystore upload, `config/prod.json`, Apple Developer, Play Console.
  Isi `APPLE_TEAM_ID` dan SHA-256 Play App Signing di file `.well-known`.
- Uji manual di HP: `docs/mobile-test-checklist.md`.
