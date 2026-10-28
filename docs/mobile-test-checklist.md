# Checklist uji di HP fisik

Test otomatis (`flutter test`) mencakup logika dan alur akun. Daftar ini untuk hal yang hanya
bisa dibuktikan di HP sungguhan. Isi kolom hasil per perangkat (minimal satu Android kelas
menengah dan satu iPhone). Item fase berikutnya ditambahkan saat fase itu dikerjakan.

Jalankan: `flutter run --flavor dev --dart-define-from-file=config/dev.json` (Android) atau
`flutter run -d <iphone> --dart-define-from-file=config/dev.json` (iPhone).

Status 28 Oktober 2026: Fase 1 dan Fase 3 lulus di iPhone 13 (iOS 26.7) dengan akun production.

## Fase 1 — Fondasi

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 1.1 | Pasang flavor dev dan prod bersamaan | Dua ikon: "L360 Dev" dan "Landscape 360" | | |
| 1.2 | Build dengan `SUPABASE_ANON_KEY` diisi service role key | Layar "Configuration error", aplikasi tidak jalan | | |
| 1.3 | Teks memakai font Inter, warna forest/gold sama dengan web | Sesuai | | |

## Fase 3 — Akun

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 3.1 | Login dengan akun production yang sama dengan web | Masuk; User Account menampilkan nama, plan, role | | |
| 3.2 | Login dengan password salah | "Wrong email or password" | | |
| 3.3 | Tutup paksa aplikasi lalu buka lagi | Masih login (sesi dari Keychain/Keystore) | | |
| 3.4 | Admin web: lihat Login history setelah 3.1 | Ada entri "Landscape 360 app on Android/iPhone" | | |
| 3.5 | Logout, lalu cek Activity di web | Ada entri logout | | |
| 3.6 | Edit profile: ubah nama, organisasi, nomor HP | Tersimpan; terlihat sama di web | | |
| 3.7 | Ganti password; coba login di browser lain yang sedang login | Browser lain keluar; password baru berlaku | | |
| 3.8 | Request account dari aplikasi | Masuk di Account Requests admin web | | |
| 3.9 | Akun dengan izin S.O.S: login, lalu mode pesawat, buka ulang aplikasi | Badge S.O.S tetap ada | | |
| 3.10 | Admin mencabut izin S.O.S, aplikasi online lagi | Badge S.O.S hilang | | |
| 3.11 | Akun admin | Tombol "Open the admin panel on the web" membuka situs | | |
| 3.12 | Lupa password | Aplikasi email terbuka ke contact@jcdigital.co.id dengan email terisi | | |
| 3.13 | Sesi diakhiri dari perangkat lain, lalu request account / aksi `/api` | Diminta login ulang, tidak crash | | |
| 3.14 | Android: `adb shell bmgr backupnow id.co.jcdigital.landscape360.dev` | Tidak ada data yang ikut backup | | |

## Fase 4a — Peta

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 4a.1 | Buka aplikasi | Peta satelit Jakarta, 2D, sheet bawah tertutup sebagian, logo Mapbox terlihat | | |
| 4a.2 | Sheet → Map → Outdoors / Streets / Satellite | Style berganti; kartu Position tetap jalan | | |
| 4a.3 | Map → 3D Terrain, geser dua jari ke atas | Peta miring, gunung timbul; di 2D peta tidak bisa dimiringkan | | |
| 4a.4 | Terrain → Exaggeration ke 3× (dalam 3D) | Relief lebih tinggi | | |
| 4a.5 | **Arahkan tanda + ke satu puncak, catat Elev di 2D, lalu pindah ke 3D** | **Elev sama (selisih < 2 m) di 2D dan 3D, mendekati Elev di web untuk titik yang sama** | | |
| 4a.6 | Lereng curam vs dataran | Slope besar di lereng, mendekati 0° di dataran | | |
| 4a.7 | Tombol lokasi (pertama kali) | Muncul izin lokasi (teks ID + EN); setelah diizinkan peta terbang ke posisi Anda | | |
| 4a.8 | Putar HP saat berdiri diam | Panah pada titik lokasi ikut arah atas HP | | |
| 4a.9 | Putar peta dua jari, lalu tombol panah merah | Peta kembali menghadap utara | | |
| 4a.10 | DD ↔ DMS di kartu Position, tutup paksa, buka lagi | Pilihan format dan style tersimpan | | |
| 4a.11 | Tolak izin lokasi, tekan tombol lokasi | Pesan "Allow it in Settings", aplikasi tidak crash | | |
| 4a.12 | Biarkan peta 3D diam 15 menit | HP tidak panas, baterai wajar | | |
| 4a.13 | Tombol Share di sheet | Lembar share iOS/Android dengan teks + link Landscape 360 | | |
| 4a.14 | Link footer (Docs, Privacy, …) | Terbuka di browser | | |
