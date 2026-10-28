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

## Fase 4b — Kompas, kontur, grid DMS

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 4b.1 | Tombol lokasi, lalu putar HP mendatar perlahan | Titik oranye dengan sorot 70° dan jarum mengikuti arah atas HP, halus, tanpa bergetar | | |
| 4b.2 | Putar peta dengan dua jari | Sorot tetap menunjuk arah yang benar di dunia nyata (bukan ikut layar) | | |
| 4b.3 | Dekat magnet / speaker, gerakkan HP acak | Muncul "Compass off: move the phone in a figure 8"; hilang sendiri setelah kompas normal | | |
| 4b.4 | Tutup petunjuk dengan X, tutup paksa aplikasi, ulangi 4b.3 | Petunjuk tidak muncul lagi | | |
| 4b.5 | Zoom ≥ 11 di daerah gunung | Garis kontur kuning; tiap garis indeks (4× interval) lebih tebal; label "2400m" di zoom ≥ 14 | | |
| 4b.6 | Terrain → interval 12.5 / 25 / 50 / 125 m (di 3D) | Kerapatan kontur berubah; label indeks 50 / 100 / 200 / 500 m | | |
| 4b.7 | Opacity Contours ke 20% | Kontur dan label memudar | | |
| 4b.8 | Zoom < 11 | Kontur hilang | | |
| 4b.9 | Grid DMS on, Auto, zoom in/out | Garis biru putus-putus, label DMS; jarak grid 5' → 1' → 30" → 15" sesuai zoom | | |
| 4b.10 | Grid interval 30" | Grid tetap 30" walau zoom berubah | | |
| 4b.11 | Geser peta, berhenti | Elev, kontur dan grid diperbarui ±0,5 detik setelah peta berhenti | | |
| 4b.12 | Mode 2D | Kontrol kontur & exaggeration redup dengan petunjuk "Contours work in 3D…"; grid tetap bisa diatur | | |

## Fase 4c — Cuaca, pencarian, route planner

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 4c.1 | Izin lokasi sudah diberikan, header sheet → ikon awan | Kartu cuaca BMKG untuk **kelurahan Anda** (mis. "Cipete Utara, Kebayoran Baru" · "Kota Adm. Jakarta Selatan · Near your location"): suhu, kondisi, kelembapan, angin, 3 hari | | |
| 4c.1b | Tolak izin lokasi, geser peta ke Bandung, buka cuaca | Kelurahan di tengah peta, keterangan "Map centre" | | |
| 4c.1c | Geser peta ke luar Indonesia (mis. Singapura), buka cuaca | "Outside BMKG coverage · Jakarta Pusat" | | |
| 4c.2 | Ketuk judul kartu cuaca | Mengecil jadi pil "32°C · Berawan"; ketuk lagi membesar; X menutup | | |
| 4c.3 | Mode pesawat, buka cuaca | "Gagal memuat data cuaca." + Try again, tidak crash | | |
| 4c.4 | Header → ikon kaca pembesar, ketik "gede" | Verified Locations (Gunung Gede dsb.) di atas, lalu Places dari Mapbox | | |
| 4c.5 | Pilih hasil | Peta terbang ke tempat itu (zoom 16) | | |
| 4c.6 | Ketik "-6.77, 106.98" | Muncul "Coordinate search (Lat, Lon)" dan hasil di titik itu | | |
| 4c.7 | Mode pesawat, cari "gede" | Verified Locations tetap muncul (dari cache / daftar bawaan) | | |
| 4c.8 | Tools → Route | Sheet turun, panel Route Planner muncul; tile Route bertanda Active | | |
| 4c.9 | Ketuk peta dua kali | Titik Start (hijau) dan Destination (oranye); rute tergambar dan peta menyesuaikan; jarak & waktu muncul | | |
| 4c.10 | Ganti mode No toll / Walk | Rute dihitung ulang, warna garis berubah (emas / hijau) | | |
| 4c.11 | Tukar (⇅), Clear, Recalculate | Bekerja sesuai nama; ketukan ketiga memulai rute baru | | |
| 4c.12 | Tutup panel (X) | Rute dan titik hilang dari peta; ketukan peta tidak lagi menambah titik | | |

## Fase 5 — Navigator Tool

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 5.1 | Tools → Navigator | Sheet turun, panel Navigator muncul; tile Navigator "Active"; Route tertutup bila tadi terbuka | | |
| 5.2 | Ketuk peta 4×  | Titik + garis lengkung kuning "Survey 1"; label jarak di tengah tiap segmen; getaran ringan | | |
| 5.3 | Geser sebuah titik | Titik dan garis ikut jari; elevasi diperbarui setelah dilepas | | |
| 5.4 | Tahan titik ±0,35 dtk lalu geser | Getaran, garis melengkung mengikuti jari; knob handle muncul | | |
| 5.5 | Ketuk titik, geser knob handle | Kedua knob berlawanan arah; lengkungan berubah | | |
| 5.6 | Ketuk area kosong peta saat titik terpilih | Pilihan hilang, tidak menambah titik | | |
| 5.7 | Straight + Angle 90°, ketuk 3 titik membentuk belokan | Belokan tepat 90°, sudut tajam | | |
| 5.8 | Corners → Sharp corner at every point | Semua titik jadi sudut tajam | | |
| 5.9 | Ketuk label jarak | Muncul azimuth • slope% dan Total | | |
| 5.10 | Ikon daftar → Points | DD, DMS, UTM, Elev per titik; Azimuth / Back Azimuth / Horiz Dist / Slope di antara titik; ganti nama, salin, hapus | | |
| 5.11 | + Sheet | "Survey 2" warna hijau, titik baru masuk ke sheet itu | | |
| 5.12 | Login, gambar survei | Ikon awan centang; survei muncul di daftar web (User Account → surveys) | | |
| 5.13 | **Buka survei itu di web** | **Titik, lengkungan, sudut tajam, nama titik identik** | | |
| 5.14 | **Buat survei di web, buka di app (ikon folder → pilih)** | **Identik; peta terbang ke survei** | | |
| 5.15 | Mode pesawat, tambah titik, lalu online lagi | Ikon awan-silang, lalu tersinkron setelah online dan ada perubahan berikutnya | | |
| 5.16 | Akun Free dengan 2 survei, New survey + titik | Pesan "Survey limit reached for "Free plan" (max : 2)." | | |
| 5.17 | Tutup paksa app, buka lagi | Survei, mode Straight dan sudut tersimpan | | |

## Fase 6 — Track Recorder

Live tracking (GPS Tracking ke monitor) belum ada di aplikasi sampai kanal `tracking-room` di backend dibuat privat (lihat `docs/security.md`).

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 6.1 | Belum login → Tools → Track | Pesan "Sign in to record and view tracks." | | |
| 6.2 | Akun Free / Pro → Track | Panel dengan gembok "Recording tracks is available for Enterprise accounts. Hubungi Admin…"; ikon folder tetap membuka daftar track | | |
| 6.3 | Akun Enterprise / admin, izin lokasi belum diberikan → Start Recording | Penjelasan "Allow location to record" muncul **sebelum** pertanyaan izin sistem | | |
| 6.4 | Start Recording (Online), berjalan 5 menit | Garis oranye di peta, waktu berjalan, Distance / Moving / Avg speed / Gain / Altitude terisi, "GPS locked · ±x m" | | |
| 6.5 | Kunci layar 10 menit sambil berjalan, buka lagi | Jalur selama layar mati tetap lengkap. iPhone: kapsul lokasi biru di status bar selama di luar app. Android: notifikasi "Recording track" | | |
| 6.6 | Pindah ke app lain 5 menit, kembali | Sama seperti 6.5 | | |
| 6.7 | Tutup panel (X) saat merekam | Pill "REC 00:12:34 · 1.20 km" di atas sheet; ketuk → panel terbuka lagi | | |
| 6.8 | Pause, jalan 50 m, Resume | Jarak tidak bertambah selama pause; garis tidak menyambung melewati jeda | | |
| 6.9 | Finish → Save Track | Track di daftar (ikon folder) berstatus SYNCED; terlihat di web (Track Recorder → My Tracks) | | |
| 6.10 | Mode pesawat, rekam (Online), Finish, lalu online lagi | Status "Waiting to sync", lalu SYNCED setelah sinyal kembali | | |
| 6.11 | Rekam mode Offline, Finish | Status PHONE ONLY; menu ⋯ → Upload to cloud mengirimnya | | |
| 6.12 | Tutup paksa app saat merekam, buka lagi | Rekaman kembali dalam status Paused dengan titik yang sudah ada; Resume melanjutkan | | |
| 6.13 | ⋯ → Show on map | Garis cyan, titik start hijau dan finish merah, peta menyesuaikan | | |
| 6.14 | ⋯ → Export GPX → simpan / kirim | File .gpx terbuka di aplikasi lain (mis. Gaia GPS, Google Earth) | | |
| 6.15 | ⋯ → Share with an account → email akun lain | "Shared with …"; akun penerima melihatnya di tab Shared (web dan app), bisa Show on map dan Export GPX | | |
| 6.16 | Penerima → ⋯ → Remove from my list | Track hilang dari Shared | | |
| 6.17 | ⋯ → Rename, ⋯ → Delete | Nama berubah (juga di web); track terhapus dari HP dan cloud | | |
| 6.18 | Rekam 30 menit dengan layar mati | Jalur utuh, baterai wajar (catat % turun) | | |
