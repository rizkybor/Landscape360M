# Checklist uji di HP fisik

Test otomatis (`flutter test`) mencakup logika dan alur akun. Daftar ini untuk hal yang hanya
bisa dibuktikan di HP sungguhan. Isi kolom hasil per perangkat (minimal satu Android kelas
menengah dan satu iPhone). Item fase berikutnya ditambahkan saat fase itu dikerjakan.

Jalankan: `flutter run --flavor dev --dart-define-from-file=config/dev.json`

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
