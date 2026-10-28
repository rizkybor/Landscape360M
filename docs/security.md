# Keamanan aplikasi Landscape 360 (Flutter)

Ditulis 28 Oktober 2026. Temuan backend rinci ada di `docs/flutter-spec.md` bagian 5.

## Yang sudah diterapkan di aplikasi

| Aturan | Di mana | Diuji oleh |
|---|---|---|
| Aplikasi menolak start bila config berisi service role key Supabase (JWT `role: service_role` atau `sb_secret_`) atau token rahasia Mapbox (`sk.`) | `lib/core/config/app_config.dart` | `test/core/app_config_test.dart` |
| Semua endpoint wajib `https` | `app_config.dart`, `usesCleartextTraffic="false"` di AndroidManifest | `app_config_test.dart` |
| Sesi Supabase disimpan di Keychain / Android Keystore (`flutter_secure_storage`), bukan SharedPreferences; iOS `first_unlock_this_device` (tidak ikut ke HP lain) | `lib/data/supabase/secure_session_storage.dart` | uji manual di HP |
| `detectSessionInUri: false`: link masuk (`?code=`, dll.) tidak pernah dianggap callback login | `lib/main.dart` | uji manual |
| Link masuk hanya diterima dari `https://landscape360.jcdigital.co.id/`, token wajib 32 hex | `IncomingLink.parse` di `lib/domain/share/share_location.dart` | `test/domain/share_location_test.dart` |
| 401 dari `/api/*`: refresh sesi sekali lalu ulangi, tidak pernah berulang tanpa batas; panggilan publik tidak mengirim token | `lib/data/api/api_client.dart` | `test/data/api_client_test.dart` |
| Ganti password memeriksa password lama dulu, lalu mengeluarkan perangkat lain | `AccountRepository.changePassword` | `test/data/account_repository_test.dart` |
| Izin S.O.S yang di-cache offline terikat per akun; dicabut admin langsung hilang begitu online | `AccountRepository.loadProfile` | `account_repository_test.dart` |
| Backup Android dimatikan (`allowBackup=false`, `data_extraction_rules.xml`): sesi & antrean S.O.S tidak ikut ke cloud backup atau pindah HP | `android/app/src/main/` | uji manual (`adb backup`) |
| Release Android memakai R8 (minify + shrink); upload key dibaca dari `android/key.properties` yang di-ignore | `android/app/build.gradle.kts` | build rilis |
| CI menolak commit yang berisi file config, keystore, atau pola secret | `.github/workflows/ci.yml` | CI |

Plan, role, `is_admin`, dan `can_use_sos` di aplikasi **hanya mengatur tampilan**. Server
tetap memeriksa ulang lewat RLS dan fungsi `SECURITY DEFINER` (contoh: `sos_report` memanggil
`can_use_sos()`), dan user tidak punya policy UPDATE di `profiles`. Aplikasi yang
dimodifikasi tidak mendapat hak tambahan.

## Temuan backend yang perlu diperbaiki di web / Supabase (bukan di aplikasi)

Diverifikasi ulang terhadap kode web:

1. **Live tracking bocor (tinggi).** `src/services/TrackerService.ts:615` memakai kanal
   Realtime `tracking-room` tanpa `private: true`, dan tidak ada policy `realtime.messages`.
   Siapa pun yang punya anon key (yang memang publik) bisa mendengar posisi semua pengguna
   yang broadcast, atau mengirim posisi palsu. **Perbaikan siap di
   `docs/backend/live-tracking/`**: kanal privat, policy `realtime.messages` (hanya monitor
   yang mendengar posisi; hanya pengguna360 Pro / Enterprise yang mengirim, lewat REST tanpa
   ikut mendengar), dan perubahan `TrackerService.ts` untuk monitor web. App hanya memakai
   kanal privat, jadi GPS Tracking di app baru jalan setelah ini diterapkan. Sisa risiko:
   isi `user_id` di paket tidak dicek server, jadi anggota yang berhak bisa memakai nama lain.
2. **Password default di repo.** `monitoring@landscape360.app` / `password123`, akun seed,
   dan `demo@landscape360.app` ada di beberapa migration dan `create_demo_user.ts`. Ganti
   password akun-akun ini di production (atau hapus akunnya), dan jangan pakai ulang untuk
   akun reviewer store.
3. Lainnya (detail di spec): `tracker_logs` tidak mengecek pemilik `session_id`; monitor
   Enterprise bisa membaca semua profil termasuk nomor HP; saran penerima share bisa dipakai
   menebak email; `file_size` basemap dilaporkan klien; batas survei hanya di klien;
   `sos_report` tanpa rate limit. Pastikan juga sign-up publik di Supabase Auth dimatikan.

## Yang belum bisa diuji di sini

Mac ini belum punya Xcode, jadi build iOS belum dicoba. Keychain, universal links, dan
background mode iOS harus diuji di iPhone fisik (lihat `docs/mobile-test-checklist.md`).
