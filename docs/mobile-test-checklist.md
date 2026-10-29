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

## Fase 6b — S.O.S (tanpa push notification)

Akun uji: satu akun biasa dengan **S.O.S diizinkan** oleh admin (User Account di web), satu akun admin. Push notification ke HP admin belum ada (butuh Firebase dan akun Apple Developer berbayar); admin melihat S.O.S saat aplikasinya terbuka (dicek tiap 30 detik).

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 6b.1 | Akun tanpa izin S.O.S / akun admin | Tidak ada tombol SOS merah di peta | | |
| 6b.2 | Akun dengan izin S.O.S: ketuk tombol SOS sekali | Tidak terjadi apa-apa | | |
| 6b.3 | Tahan tombol SOS | "Keep holding… 3/2/1", getar tiap detik, cincin putih terisi; setelah 3 dtk layar merah hitung mundur 5 | | |
| 6b.4 | Saat hitung mundur tekan Cancel | Kembali ke peta; admin tidak menerima apa pun | | |
| 6b.5 | Biarkan hitung mundur selesai | "S.O.S ACTIVE", posisi DMS / desimal / UTM, elevasi, akurasi, baterai; "Sent to the admin hh:mm" | | |
| 6b.6 | Admin (web atau app): S.O.S alerts | S.O.S muncul dengan posisi, baterai, waktu; di app admin: banner merah "1 active S.O.S · View" dan penanda merah di peta | | |
| 6b.7 | Kirim pesan dari layar S.O.S | Admin melihat pesannya | | |
| 6b.8 | Kunci layar HP 2 menit, jalan sedikit | Admin melihat posisi terus diperbarui (jumlah positions bertambah); iPhone: kapsul lokasi biru | | |
| 6b.9 | Mode pesawat 2 menit, lalu matikan mode pesawat | Status "Waiting for signal…", lalu "Sent to the admin" sendiri setelah sinyal kembali | | |
| 6b.10 | Emergency 112 / Basarnas 115 | Aplikasi Telepon terbuka dengan nomornya (jangan tekan panggil saat uji) | | |
| 6b.11 | Emergency contacts → tambah 1 kontak → SMS (1) | Aplikasi Pesan terbuka dengan teks S.O.S berisi koordinat dan link peta | | |
| 6b.12 | Share location | Lembar berbagi berisi teks S.O.S | | |
| 6b.13 | Siren, dengan tombol senyap iPhone menyala | Sirene tetap berbunyi; Stop siren menghentikan | | |
| 6b.14 | S.O.S light | Senter dan layar berkedip pola ··· ——— ··· | | |
| 6b.15 | Layar dibiarkan 5 menit | Layar tidak meredup / terkunci sendiri | | |
| 6b.16 | I'm safe (dalam mode pesawat), lalu online lagi | Layar tertutup; setelah online, admin melihat S.O.S berstatus RESOLVED | | |
| 6b.17 | Admin: Show on map / Call / WhatsApp / Mark resolved + catatan / Delete di History | Sesuai nama; banner hilang setelah resolved | | |
| 6b.18 | Admin: halaman akun → Open S.O.S screen | Layar S.O.S yang sama terbuka (admin tidak punya tombol di peta) | | |

## Fase 7a — POIs, Share Location, link masuk

Link masuk (`?at=`, `?place=`) baru bisa dibuka langsung dari WhatsApp setelah domain diverifikasi di Fase 8 (universal links / App Links; iPhone butuh akun Apple Developer berbayar). Logikanya sudah diuji di simulator.

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7a.1 | Zoom ke Gunung Gede (zoom ≥ 10) | Titik POI berwarna per kategori (hijau puncak, biru mata air, …); dari jauh tergabung jadi lingkaran oranye bernomor | | |
| 7a.2 | Ketuk lingkaran bernomor | Peta zoom masuk | | |
| 7a.3 | Ketuk satu titik | Kartu: nama, kategori, ketinggian, koordinat, deskripsi (Wikipedia) | | |
| 7a.4 | Ketuk area kosong peta / X | Kartu tertutup | | |
| 7a.5 | Tools → POIs | Titik hilang, tile tidak "Active"; ketuk lagi: titik kembali, sheet turun. Pilihan tetap setelah app ditutup | | |
| 7a.6 | Navigator aktif, ketuk sebuah titik POI | Titik survei ditambahkan di sana (kartu POI tidak terbuka) | | |
| 7a.7 | Tombol Share Location (ikon pin berbagi, kanan) | "Getting your location…", lalu DMS, mdpl, ±m | | |
| 7a.8 | Send to WhatsApp | WhatsApp terbuka dengan pesan lokasi (link Google Maps + Landscape 360) | | |
| 7a.9 | Other apps / Copy | Lembar berbagi / "Copied" | | |

## Fase 7b — Marked Locations

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7b.1 | Belum login → Tools → Marked | "Sign in to save your own locations." | | |
| 7b.2 | Login → Tools → Marked | Sheet "Marked Locations": Mine / Shared (/ All untuk admin), jumlah "n / batas plan" | | |
| 7b.3 | Add → isi nama, pilih kategori → Pick on map → ketuk peta | Form tertutup, bar "Tap the map…"; setelah ketuk, form terbuka lagi dengan lat/lng/elevasi terisi dan nama tetap | | |
| 7b.4 | Save Location | Penanda bulat warna kategori dengan ikon, nama di atasnya (zoom ≥ 11); peta ke lokasi; juga muncul di web | | |
| 7b.5 | Ketuk penanda | Kartu: nama, kategori, mdpl; ˄ detail (DMS, alamat, catatan, tag); Directions, Copy, In list. Ketuk lagi / X: tertutup | | |
| 7b.6 | Map center / My GPS di form | Koordinat terisi dari tengah peta / GPS | | |
| 7b.7 | ⋯ → Edit / Delete | Berubah / terhapus (juga di web) | | |
| 7b.8 | Cari "pos" / tag | Daftar tersaring | | |
| 7b.9 | Centang beberapa → GPX | File .gpx bisa dibuka aplikasi lain | | |
| 7b.10 | Akun Pro/Enterprise: ⋯ → Share → pilih "Recent" atau ketik nama/email | "Shared location with …"; penerima melihatnya di tab Shared (penanda bercincin emas) | | |
| 7b.11 | Share → Create link → Send to WhatsApp / Copy | Pesan berisi link `?place=`; di browser link membuka lokasi tanpa login | | |
| 7b.12 | Turn off link | Link lama tidak bisa dibuka lagi ("no longer available") | | |
| 7b.13 | Akun Free: Share tidak ada; di batas 10 lokasi tombol Add mati | Pesan batas plan dan "Hubungi Admin" | | |
| 7b.14 | Admin: tab All + "Show every account's locations" | Penanda akun lain bercincin abu-abu | | |
| 7b.15 | Track Recorder → My Tracks → Share (regresi) | Kolom email + tombol Share tampil normal (sebelumnya bisa crash) | | |

## Fase 7c — Marked Areas

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7c.1 | Belum login → Tools → Areas | "Sign in to draw and save areas." | | |
| 7c.2 | Login → Tools → Areas | Panel "Marked Areas" di atas sheet, jumlah "n / batas plan" (Free 5, Pro 10, Enterprise 20) | | |
| 7c.3 | Add area → ketuk 4 sudut di peta | Garis putus-putus emas tertutup, titik pertama hijau; bar "4 points · luas" | | |
| 7c.4 | Undo | Titik terakhir hilang | | |
| 7c.5 | Done → isi nama, pilih warna, catatan → Save area | Area berwarna tipis dengan garis tepi dan nama; muncul juga di web | | |
| 7c.6 | Ikon mata (Focus) | Peta menyesuaikan ke area, sekelilingnya gelap; pill "Exit focus" saat panel ditutup | | |
| 7c.7 | ⋯ → Edit → Redraw | Bisa menggambar ulang dari sudut lama; ukuran diperbarui | | |
| 7c.8 | Ketuk sebuah area di peta | Panel Areas terbuka dengan area itu disorot | | |
| 7c.9 | Navigator aktif, ketuk di dalam area | Titik survei ditambahkan (panel area tidak terbuka) | | |
| 7c.10 | Pro/Enterprise: ⋯ → Share as a link → Create link → WhatsApp / Copy | Pesan berisi luas, keliling dan link `?area=` | | |
| 7c.11 | Buka link `?area=` di browser | Area tampil dalam mode fokus tanpa login | | |
| 7c.12 | Turn off link | Link lama: "no longer available" | | |
| 7c.13 | ⋯ → Delete | Area terhapus (juga di web) | | |

## Fase 7d — Peta offline

Batas sama dengan web (dicek ulang server): Free 1 peta ≤ 1 MB, Pro 3 peta ≤ 10 MB, Enterprise/admin 10 peta ≤ 25 MB. Yang diunduh: zoom saat ini sampai +2 (maks. 16).

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7d.1 | Sheet → Map → Offline maps (belum login) | "Sign in to download offline maps." | | |
| 7d.2 | Login → Offline maps | Daftar kosong, "0 of n maps · up to x MB each" | | |
| 7d.3 | Download an area | Sheet turun, bingkai putih di peta (luar bingkai gelap), bar unduh di bawah | | |
| 7d.4 | Geser / zoom peta | "Zoom a–b · n tiles · ≈ x MB of y MB" ikut berubah | | |
| 7d.5 | Area terlalu besar untuk plan | Teks merah, tombol Download mati | | |
| 7d.6 | Beri nama → Download | Pesan "Downloading…"; Map → Offline maps menunjukkan progres % | | |
| 7d.7 | Selesai | "On this phone · x MB"; juga tercatat di web (Offline Maps) | | |
| 7d.8 | **Tutup app, nyalakan mode pesawat, buka app, ke area itu** | **Peta tampil (satelit / jalan), 3D dan kontur jalan, ketinggian di kartu telemetri terisi** | | |
| 7d.9 | Mode pesawat, geser ke area yang tidak diunduh | Peta kosong di sana (wajar) | | |
| 7d.10 | Peta yang diunduh di HP / web lain | "Not on this phone" → ⋯ → Download to this phone | | |
| 7d.11 | ⋯ → Show on map / Delete | Peta ke area itu / terhapus dari HP dan akun | | |

## Fase 7e — Basemap kustom (Enterprise / admin)

Unggah basemap (GeoTIFF / PDF) tetap lewat web; aplikasi menampilkannya.

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7e.1 | Belum login → Tools → Basemaps | "Sign in to use your custom basemaps." | | |
| 7e.2 | Akun Free / Pro → Basemaps | Gembok "available for Enterprise accounts" | | |
| 7e.3 | Akun Enterprise: unggah satu basemap di web, lalu Basemaps di app | Basemap muncul di daftar dengan ukuran; pemakaian "x MB of 5 MB" | | |
| 7e.4 | Nyalakan (switch) | Gambar tampil di peta di posisinya, di bawah penanda / area / garis; "on this phone" | | |
| 7e.5 | Geser Opacity | Gambar makin transparan | | |
| 7e.6 | Ikon fokus | Peta menyesuaikan ke basemap | | |
| 7e.7 | **Mode pesawat, tutup & buka app** | **Basemap yang menyala tetap tampil** | | |
| 7e.8 | Matikan di app | Hilang dari peta; di web juga mati | | |
| 7e.9 | ⋯ → Delete | Hilang dari app dan web | | |

## Fase 7f — Ekspor laporan

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7f.1 | Navigator: buat 4–6 titik di 2 sheet, tutup Navigator; tombol kamera (kanan) | Pilihan Save as PNG / Save as JPG / Export to PDF | | |
| 7f.2 | Export to PDF | "Preparing the report…", lalu lembar berbagi dengan satu PDF | | |
| 7f.3 | Buka PDF (Files / Books) | Halaman 1: header, peta seperti di layar dengan titik bernomor + mdpl, kotak Map Center / elevasi / heading / zoom, tabel titik (kolom Line karena 2 sheet). Halaman 2: profil elevasi dengan Min/Max/Total/Gain, Marked Locations yang terlihat di peta | | |
| 7f.4 | Angka di tabel | Dist. dan Total sama dengan daftar Points di Navigator; Total mulai dari 0 di setiap sheet | | |
| 7f.5 | Save as JPG | Satu JPG per halaman, bisa disimpan ke Photos | | |
| 7f.6 | Tanpa titik survei | Laporan tetap dibuat: peta + "No Survey Data Available" | | |
| 7f.7 | Ukuran file | PDF 2 halaman kira-kira < 2 MB | | |

## Fase 7g — GPS Tracking (dilacak monitor)

Butuh dulu: migration dan perubahan web di `docs/backend/live-tracking/` sudah diterapkan.

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 7g.1 | Login akun monitor360 Enterprise → Tools | Tidak ada tile GPS (monitor memantau di web) | | |
| 7g.2 | Login pengguna360 Free → Tools → GPS | Pesan "available for Pro and Enterprise", tanpa tombol Start | | |
| 7g.3 | Login pengguna360 Pro / Enterprise → Tools → GPS → Start sharing | Status "Sharing · sent just now", pill LIVE di peta | | |
| 7g.4 | Buka Team Monitor di web (monitor360 Enterprise) | Anggota muncul dengan nama email sebelum @ (kapital) dan baterai asli, bergerak tiap beberapa detik | | |
| 7g.5 | Kunci layar HP 5 menit sambil jalan | Posisi di web terus bergerak; iPhone menampilkan indikator lokasi biru | | |
| 7g.6 | Mode pesawat 1 menit, lalu matikan | Pill "waiting for signal", lalu posisi langsung terkirim lagi | | |
| 7g.7 | Monitor membuka Team Monitor saat anggota diam | Posisi anggota muncul segera (jawaban heartbeat) | | |
| 7g.8 | Stop sharing | Pill hilang; anggota menjadi offline di web setelah 60 dtk | | |
| 7g.9 | Akun tanpa login di web/anon mencoba dengar `tracking-room` | Ditolak (kanal privat) | | |

## Fase 8 — Kepatuhan store

Butuh dulu: file di `docs/backend/store/` sudah disalin ke web dan ter-deploy.

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 8.1 | User Account → About Landscape 360 | Versi app, link User guide, FAQ, Reviews, Contact support, Privacy, Terms, Deleting your account | | |
| 8.2 | Quick Start Guide → About, privacy and support | Halaman About terbuka (juga tanpa login) | | |
| 8.3 | Login admin → User Account | Tidak ada Delete account | | |
| 8.4 | Akun uji → Delete account → Cancel | Tidak ada yang terhapus | | |
| 8.5 | Delete account → Continue → password salah + DELETE | "Your password is not correct", akun tetap ada | | |
| 8.6 | Saat merekam track → Delete account | Pesan "Stop and save the track…", tidak lanjut | | |
| 8.7 | Password benar + DELETE → Delete my account forever | Kembali ke peta, "Your account has been deleted."; login dengan akun itu gagal; track lokal dan kontak darurat akun itu hilang | | |
| 8.8 | Buka https://landscape360.jcdigital.co.id/delete-account | Halaman publik menjelaskan cara dan isi yang dihapus | | |
| 8.9 | Laporan PNG → share sheet → Save Image (iPhone) | Minta izin Foto dengan teks Landscape 360, gambar tersimpan, app tidak crash | | |
| 8.10 | Android 13+: mulai rekam track | Minta izin notifikasi; notifikasi "Landscape 360 is using GPS" tampil | | |
| 8.11 | Ketuk link `?at=` di WhatsApp (Android, setelah assetlinks ter-deploy) | Terbuka langsung di app | | |


## Fase 9 — Pengujian & performa

Otomatis (diulang sebelum setiap rilis):

| Uji | Perintah | Hasil 29 Okt 2026 |
|---|---|---|
| Unit + widget (termasuk 5 ukuran layar × teks 100% / 130%) | `flutter test` | Lulus |
| Peta diam tidak menggambar ulang | `flutter test integration_test/idle_frames_test.dart -d <sim/HP> --dart-define-from-file=config/dev.json` | iPhone 15 sim: 1 frame dalam 6 dtk; geser peta p90 build 0,62 ms |
| Login → survei → simpan ke cloud | `flutter test integration_test/survey_flow_test.dart -d <sim/HP> --dart-define-from-file=config/dev.json --dart-define=L360_TEST_EMAIL=… --dart-define=L360_TEST_PASSWORD=…` | Butuh akun uji (dilewati tanpa kredensial) |
| Gesture Navigator, layer peta, offline, basemap, laporan, kontrol pudar | `integration_test/*.dart` | Lulus di simulator |

Manual di HP fisik (minimal satu Android menengah dan satu iPhone):

| # | Langkah | Hasil yang diharapkan | Android | iPhone |
|---|---|---|---|---|
| 9.1 | Rekam track 30 menit, layar mati | Baterai turun wajar (catat %), track utuh | | |
| 9.2 | GPS Tracking 30 menit, layar mati | Posisi terus terkirim, baterai wajar | | |
| 9.3 | Xcode Instruments → Energy Log, peta diam 1 menit | Energy Impact "Low" | | |
| 9.4 | Android Studio Profiler, peta diam 1 menit | CPU app mendekati 0% | | |
| 9.5 | HP lama (Android 10 / iPhone SE) | Peta 3D dan sheet tetap lancar | | |
| 9.6 | iPad | Sheet, Tools dan halaman akun rapi | | |
