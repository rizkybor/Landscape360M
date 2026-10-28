# Landscape 360 — Rencana & Prompt Aplikasi Native Flutter (Android / iPhone)

Dokumen ini adalah rencana kerja sekaligus kumpulan prompt untuk membangun Landscape 360
sebagai **aplikasi native** dengan **Flutter**: satu codebase Dart yang dikompilasi menjadi
aplikasi native Android dan iPhone, dengan peta, GPS, kompas, dan notifikasi memakai SDK native
masing-masing platform. Targetnya sampai siap diunggah ke Google Play dan App Store.

**Cara memakai:** kerjakan per fase, berurutan. Untuk tiap fase, salin blok **Prompt** ke AI
coding agent (Claude Code atau sejenisnya), bersama bagian **Konteks project** di bawah. Buka
agent di folder yang berisi web app ini **dan** project Flutter, supaya agent bisa membaca kode
web sebagai acuan. Jangan menjalankan semua fase dalam satu prompt; tiap fase punya kriteria
selesai yang perlu dicek dulu di HP sungguhan.

> Diperbarui 28 Oktober 2026, berdasarkan kode web Landscape 360 v3.3.0 (termasuk S.O.S,
> kompas, Share Location, link lokasi/area, Marked Areas, dan desain sidebar baru). Versi paket Flutter dan
> aturan store (biaya, target API, jumlah tester, formulir) berubah dari waktu ke waktu: cek
> ulang di pub.dev, Play Console, dan App Store Connect sebelum memulai tiap fase.
>
> Alternatif yang lebih cepat (membungkus web app yang ada dengan Capacitor) dijelaskan di
> `MOBILE_APP_PROMPT.md`. Bagian 2 membandingkan keduanya.

---

## 1. Konteks project (sertakan di setiap prompt)

```text
Landscape 360 adalah aplikasi navigasi digital untuk penggiat alam terbuka (pendaki, pecinta
alam, komunitas outdoor). Versi web sudah berjalan (React + Mapbox GL JS + Supabase). Kita
membangun aplikasi Flutter yang memakai BACKEND YANG SAMA, tanpa mengubah perilaku web.

Tagline: "Explore without Limits". Bahasa UI: Inggris (teks izin dan pesan share ID + EN).

Fitur web yang menjadi acuan:
- Peta topografi 2D / 3D terrain (Mapbox), style Streets / Outdoors / Satellite, kontur
  (interval, opacity, exaggeration), grid DMS, kompas, pitch/bearing, telemetry koordinat
  (DD / DMS), elevasi & slope, pilihan "Drag to: Move the map / Look around" (desktop)
- Titik lokasi user dengan JARUM KOMPAS: arah tepi atas HP (sensor magnetometer), ikut
  berputar saat HP diputar, tetap benar saat peta diputar, fallback ke arah GPS saat bergerak,
  petunjuk kalibrasi kecil ("move the phone in a figure 8") yang bisa ditutup permanen
- Navigator Tool: tap untuk menambah titik, drag untuk memindah, tahan lalu geser untuk
  membuat lengkungan (handle Bezier), mode Straight dengan snap sudut (Free/15°/45°/90°),
  sudut per titik (lengkung/siku), beberapa sheet per survei, jarak & azimuth Vincenty WGS84,
  slope, label jarak per segmen, simpan survei ke cloud
- Rekam track GPS (Track Recorder: rekam Enterprise/admin, lihat & share semua akun login),
  export GPX, live tracking tim (broadcast Pro/Enterprise, monitor Enterprise monitor360)
- Marked Locations (10 kategori dengan ikon, batas Free 10 / Pro 100 / Enterprise 1.000,
  share ke akun lain dengan saran penerima, share sebagai LINK yang bisa dibuka tanpa login)
- Marked Areas: polygon yang digambar dengan tap sudut-sudutnya, luas & keliling WGS84, mode
  FOKUS (di luar area digelapkan), share sebagai link tanpa login (batas Free 5 / Pro 10 /
  Enterprise 20 / admin tanpa batas; link hanya Pro, Enterprise, admin)
- Share Location: kirim posisi GPS saat ini (bukan live) ke WhatsApp / aplikasi lain / copy,
  dengan DMS, desimal, elevasi, akurasi, link Google Maps dan link Landscape 360 (?at=lat,lng)
- Share aplikasi (link https://landscape360.jcdigital.co.id/ ke WhatsApp / copy)
- S.O.S (hanya akun yang diizinkan admin + admin): tahan 3 detik, hitung mundur 5 detik,
  layar darurat (GPS DMS/desimal/UTM, elevasi, baterai), telepon 112 / Basarnas 115, SMS ke
  kontak darurat berisi lokasi, sirine, lampu kedip Morse, laporan ke admin tiap 30 detik
  (pesan, lokasi, baterai, jejak) dengan antrean offline, "I'm safe" mengakhiri alert
- Offline maps (unduh wilayah, batas per plan), basemap kustom GeoTIFF / GeoPDF (Enterprise),
  Points of Interest (dibaca semua, dikelola admin)
- Cuaca BMKG, pencarian lokasi, route planner (kendaraan via tol / tanpa tol, jalan kaki),
  export laporan PNG/JPG/PDF (peta + titik survei + marked locations + tabel + profil elevasi)
- Cloud storage per plan (Free 10 MB / Pro 100 MB / Enterprise 1 GB / admin tanpa batas)
- Akun: login email + password (tidak ada login Google/Apple), request account, edit profil
  (display_name, organization, phone), ganti password sendiri, review, plan
  Free/Pro/Enterprise, role pengguna360/monitor360, akun admin (is_admin), izin can_use_sos
- Admin: Manage Users (termasuk izin S.O.S), Account Requests, User Activity, Broadcast via
  Gmail, S.O.S Alerts (banner, marker, riwayat, resolve, hapus), kelola POI

Backend (sudah ada, dipakai ulang):
- Supabase: auth, Postgres dengan RLS, storage, RPC (record_login, record_logout,
  update_my_contact, admin_storage_overview, sos_report, admin_sos_alerts,
  share_marked_locations, marked_location_share_suggestions, create/get/revoke/open
  _marked_location_link, create/get/revoke/open_marked_area_link, dll). Lihat
  supabase/migrations/ (terbaru: 0012 POI, 0013 basemaps Enterprise, 0014–0016 S.O.S,
  0017 perbaikan share, 0018 link lokasi, 0019 Marked Areas)
- Vercel Functions: https://landscape360.jcdigital.co.id/api/admin-users dan
  /api/account-requests, dipanggil dengan header Authorization: Bearer <access token>
- Situs web: https://landscape360.jcdigital.co.id (privacy, terms, reviews, faq, docs)
- Link share yang harus dibuka di aplikasi (universal links / app links), dan tetap di web
  kalau aplikasi belum terpasang: /?at=lat,lng (titik), /?place=<token> (marked location),
  /?area=<token> (marked area, langsung mode fokus). Pembuka link tidak perlu login.
- Saat server menolak token (401), perbarui sesi sekali lalu ulangi (lihat src/lib/authFetch.ts)

Acuan logika di repo web (port ke Dart beserta test-nya, hasil harus identik):
- src/utils/surveyUtils.ts (+ surveyUtils.test.ts): Vincenty WGS84, azimuth, snapToAngle,
  buildSurveyLine / segmentMidpoints (Bezier), toDMS, toUTM
- src/utils/trackRecorderGeo.ts, src/utils/markedLocations.ts, src/lib/storageUsage.ts,
  src/lib/adminEmail.ts (planBroadcast), src/lib/profileContact.ts (whatsappUrl, isValidPhone)
- src/utils/markedAreas.ts (ringArea, ringPerimeter, focusMask, batas plan),
  src/lib/shareLocation.ts (format pesan & link share), src/lib/sos.ts + sosAlerts.ts
  (pesan SMS, URL sms:, pola Morse, outbox laporan), src/lib/deviceHeading.ts (arah kompas,
  deteksi kompas belum terkalibrasi), src/lib/authFetch.ts
- UI mobile web sebagai acuan tata letak: src/components/ControlPanel.tsx (sheet bawah dengan
  tab Tools / Map / Terrain, ikon Guide/Share/Weather/Search di header, sheet turun otomatis
  saat panel alat dibuka)
- Dokumen: ARCHITECTURE.md, SECURITY.md, Tracker.md, TrackRecorder.md

Aturan kerja:
- Project Flutter di folder terpisah (mis. ../landscape360_app atau mobile/), web tidak diubah
  kecuali fase yang memintanya (mis. endpoint hapus akun)
- Jangan pernah menaruh service role key Supabase atau secret apa pun di aplikasi. Aplikasi
  hanya memakai anon key + sesi user; aksi admin lewat Vercel Functions
- Setiap logika yang di-port wajib punya test Dart dengan kasus yang sama seperti test web
- Jalankan `flutter analyze` dan `flutter test` setelah perubahan; uji GPS, offline, dan
  background di HP fisik
```

---

## 2. Kenapa Flutter, dan konsekuensinya

| | Flutter (dokumen ini) | Capacitor (`MOBILE_APP_PROMPT.md`) |
|---|---|---|
| Kode | Tulis ulang UI + logika dalam Dart | ±90% kode web dipakai ulang |
| Peta | **Mapbox Maps SDK native**: lebih mulus, hemat baterai, offline bawaan (TileStore) | Mapbox GL JS di WebView; offline iOS perlu solusi khusus |
| GPS background | Plugin native matang | Perlu plugin, logika tetap di JS |
| Risiko ditolak Apple 4.2 | Rendah (aplikasi native) | Lebih tinggi (dianggap website dibungkus) |
| Biaya pengembangan | Tinggi (dua codebase: web + Flutter) | Rendah |
| Pemeliharaan | Fitur baru harus dibuat dua kali | Satu codebase |

**Konsekuensi yang harus disadari sejak awal:**
1. Setiap fitur web baru perlu dibuat ulang di Flutter. Tentukan fitur mana yang **wajib ada
   di aplikasi**, dan mana yang tetap **web saja**.
2. **Rekomendasi cakupan v1 aplikasi:** fitur lapangan (peta + kompas, Navigator Tool,
   rekam track, offline map, Marked Locations & Areas, Share Location, S.O.S, cuaca, akun).
   **Panel admin tetap di web** (Manage Users, Account Requests, User Activity, Broadcast,
   kelola POI), karena dipakai di laptop dan tidak perlu fitur HP. Pengecualian: admin
   sebaiknya **menerima notifikasi S.O.S di HP** (lihat Fase 6b).
3. **Yang justru lebih baik di aplikasi native daripada web:** rekam track & S.O.S tetap
   jalan saat layar mati, kompas lebih stabil, notifikasi push S.O.S ke admin, peta offline
   bawaan Mapbox, link share yang langsung membuka aplikasi.
4. Biaya Mapbox untuk SDK mobile dihitung berbeda dari web (berbasis pengguna aktif bulanan).
   Cek perkiraan biaya di dashboard Mapbox sebelum rilis.

---

## 3. Pilihan teknologi

| Kebutuhan | Paket Flutter (cek versi terbaru di pub.dev) | Catatan |
|---|---|---|
| Peta, 3D terrain, offline | `mapbox_maps_flutter` (resmi Mapbox) | Butuh **secret downloads token** Mapbox untuk build (Gradle / `.netrc`), terpisah dari public token |
| Alternatif peta | `maplibre_gl` | Kalau biaya Mapbox jadi masalah; style & tile perlu sumber lain |
| Backend | `supabase_flutter` | Auth, query, RPC, storage, realtime (live tracking) |
| State | `flutter_riverpod` | Setara Zustand di web |
| Routing | `go_router` | Deep link `/reviews`, `/docs` bisa dibuka ke web |
| Lokasi | `geolocator` + `flutter_background_geolocation` (Transistorsoft, berbayar untuk rilis Android) atau `background_location` | Rekam track saat layar mati |
| Data lokal | `drift` (SQLite) | Track rekaman, survei offline, antrean sinkron |
| Sesi & rahasia lokal | `flutter_secure_storage` | Token sesi Supabase |
| Geodesi | Port `surveyUtils.ts` sendiri (Vincenty) | Jangan pakai rumus haversine; hasil harus sama dengan web |
| File & share | `path_provider`, `share_plus`, `file_picker` | Export GPX/PDF, upload basemap |
| PDF | `pdf` + `printing` | Export laporan |
| Link keluar | `url_launcher` | Gmail, mailto, WhatsApp (wa.me), BMKG |
| Haptics | `HapticFeedback` (bawaan) | Saat menambah titik, mode lengkung aktif, tombol S.O.S ditahan |
| Kompas | `flutter_compass` atau `sensors_plus` (magnetometer + accelerometer) | Arah tepi atas HP; akurasi/kalibrasi dari platform (iOS heading accuracy, Android sensor accuracy) |
| Baterai, telepon, SMS | `battery_plus`, `url_launcher` (`tel:`, `sms:`) | Layar S.O.S; SMS tetap dibuka di aplikasi pesan HP (tidak kirim otomatis) |
| Senter & suara | `torch_light`, `audioplayers` | Lampu kedip Morse dan sirine S.O.S (lebih terang dari layar putih di web) |
| Layar tetap menyala | `wakelock_plus` | Layar S.O.S dan saat merekam |
| Link masuk | `app_links` | Universal links (iOS) / App Links (Android) untuk `?at=`, `?place=`, `?area=` |
| Push notification | `firebase_messaging` (FCM, juga untuk iOS via APNs) | Notifikasi S.O.S ke admin; butuh Supabase Edge Function / webhook untuk mengirim |
| Notifikasi | `flutter_local_notifications` | Notifikasi saat merekam track atau S.O.S aktif (Android foreground service) |
| Crash & analytics | `sentry_flutter` atau Firebase Crashlytics | Wajib sebelum rilis |

**GeoTIFF / GeoPDF:** belum ada library Dart yang setara `geotiff` + `pdfjs` + `proj4`.
Pilihan: (a) proses di server (Vercel Function / Supabase Edge Function dengan GDAL) yang
mengembalikan gambar + bounds, lalu aplikasi menampilkannya sebagai image source; atau
(b) basemap kustom tetap diunggah dari web, aplikasi hanya menampilkan hasilnya. **Rekomendasi
v1: opsi (b).**

---

## 4. Fase dan prompt

### Fase 0 — Keputusan & spesifikasi

**Prompt**

```text
Baca kode web Landscape 360 (src/, api/, supabase/migrations/, ARCHITECTURE.md, SECURITY.md,
Tracker.md, TrackRecorder.md). Jangan menulis kode Flutter dulu. Buat docs/flutter-spec.md:
1. Daftar fitur web + keputusan per fitur: "app v1", "app nanti", atau "web saja"
   (rekomendasi awal: admin web saja, basemap kustom hanya ditampilkan)
2. Semua tabel, kolom, RPC, policy RLS, dan endpoint /api yang dipakai aplikasi, dengan
   bentuk request/response
3. Model data Dart (freezed) untuk SurveyGroup, SurveyPoint (corner, handle), track, marked
   location, marked area (ring, area_m2, perimeter_m, color), share link, SOS alert/report,
   profile (termasuk can_use_sos), plan, role
4. Daftar fungsi logika yang harus di-port beserta file test web yang menjadi acuan
5. Risiko & pertanyaan yang perlu saya jawab
```

**Selesai jika:** spesifikasi disetujui, termasuk daftar fitur v1 dan app ID final
(usulan `id.co.jcdigital.landscape360`, tidak bisa diubah setelah rilis), serta keputusan
push notification S.O.S (FCM) dan universal links.

### Fase 1 — Fondasi project

**Prompt**

```text
Buat project Flutter baru sesuai docs/flutter-spec.md:
- Flavor dev dan prod (applicationId / bundle ID berbeda untuk dev), konfigurasi lewat
  --dart-define-from-file (SUPABASE_URL, SUPABASE_ANON_KEY, MAPBOX_PUBLIC_TOKEN, API_BASE_URL).
  File konfigurasi tidak di-commit; sediakan contoh .example
- Struktur: lib/core (config, theme, router), lib/data (supabase, api, repositories),
  lib/domain (models, logika murni), lib/features/<fitur>
- Tema mengikuti palet web (forest, gold, sand, brick, ink, ember dari src/index.css), font
  Inter (sama dengan web, dibundel di aplikasi), ikon aplikasi dan splash dari logo
  Landscape 360 dengan tagline "Explore without Limits"
- Riverpod + go_router, lint ketat (very_good_analysis atau flutter_lints + aturan tambahan)
- CI: flutter analyze + flutter test di setiap push
Jangan menaruh secret di repo.
```

**Selesai jika:** aplikasi kosong berjalan di emulator Android dan simulator iOS untuk kedua
flavor, CI hijau.

### Fase 2 — Port logika inti + test

**Prompt**

```text
Port logika murni ke lib/domain dalam Dart, TANPA UI, masing-masing dengan test yang memakai
kasus yang sama persis dengan test web:
- surveyUtils.ts: geodesicInverse (Vincenty WGS84, termasuk kasus Flinders Peak → Buninyong),
  getAzimuthData, snapToAngle, buildSurveyLine, segmentMidpoints, handleFromDrag, handleEnds,
  toDMS, toUTM, formatDistance, formatDegrees
- trackRecorderGeo.ts, markedLocations.ts, markedAreas.ts (luas, keliling, focusMask,
  batas plan), storageUsage.ts, profileContact.ts, shareLocation.ts (pesan & link),
  sos.ts (buildSosMessage, smsUrl, SOS_LIGHT_PATTERN), deviceHeading.ts
  (createCompassQualityTracker)
Hasil numerik harus sama dengan web sampai 6 desimal. Tulis tabel perbandingan nilai web vs
Dart di test.
```

**Selesai jika:** semua test Dart lulus dan nilainya cocok dengan test web.

### Fase 3 — Akun

**Prompt**

```text
Implementasikan akun dengan supabase_flutter:
- Login email + password, logout (panggil RPC record_logout sebelum signOut, record_login
  setelah login, seperti web), sesi disimpan di flutter_secure_storage
- Request account (form sama dengan web: full name, email, organization opsional, phone
  opsional 8–15 digit, message) ke POST /api/account-requests
- User Account: nama dari display_name (cadangan full_name/name), email, organization, phone,
  badge plan/role, pemakaian storage; Edit Profile (display_name + update_my_contact)
- Lupa password: buka email ke admin seperti web (url_launcher); ganti password sendiri
  (form sama dengan ChangePasswordForm web)
- Muat can_use_sos dan is_admin dari profiles; simpan lokal supaya tombol S.O.S tetap muncul
  saat offline
- Panggilan ke /api/*: kalau dapat 401, refreshSession() sekali lalu ulangi; kalau tetap
  gagal, minta login ulang (sama seperti authFetch.ts)
- Admin yang login di aplikasi melihat tombol "Buka panel admin di web"
```

**Selesai jika:** login, request account, edit profil berfungsi dengan data production yang
sama seperti di web.

### Fase 4 — Peta

**Prompt**

```text
Bangun layar peta dengan mapbox_maps_flutter:
- Style Outdoors / Satellite / Streets, mode 2D dan 3D terrain (exaggeration sama dengan web),
  sky, kompas, zoom, reset bearing, pitch
- Lokasi user (titik + akurasi), tombol "ke lokasi saya"; GPS berhenti saat app di
  background kecuali sedang merekam track atau S.O.S aktif
- Jarum kompas + sorot arah (70°) di titik lokasi: arah tepi atas HP dari sensor, tetap benar
  saat peta diputar, gerakan halus (abaikan perubahan < 1,5°, putar lewat jalur terpendek),
  fallback arah GPS saat bergerak; petunjuk kalibrasi kecil satu kali per sesi, bisa ditutup
  permanen (logika di deviceHeading.ts)
- Telemetry: koordinat tengah peta (DD / DMS, pilihan disimpan), elevasi (queryTerrainElevation),
  slope, pitch, bearing
- Kontur dan grid DMS sebagai layer (ambil acuan perhitungan dari GridDMSLayer dan
  ContourLayer web)
- Tata letak seperti versi mobile web terbaru: bottom sheet dengan tab Tools / Map /
  Terrain, header berisi Guide, Share (aplikasi), Weather, Search; sheet turun otomatis saat
  panel alat dibuka (Navigator, Route, Track, Marked, Areas, Basemaps) dan naik lagi saat
  ditutup; footer Docs · Reviews · FAQ · Terms · Privacy + "Powered by Jendela Cakra Digital ·
  Makopala Univ. Budi Luhur"
- Cuaca BMKG, route planner (panel bawah, tidak menutupi tombol zoom/kompas)
Batasi frame rate saat idle dan jangan memaksa render terus-menerus (pelajaran dari audit
performa web: peta tidak boleh menggambar ulang tanpa henti).
```

**Selesai jika:** peta lancar di HP menengah, tidak panas setelah 15 menit di mode 3D.

### Fase 5 — Navigator Tool

**Prompt**

```text
Implementasikan Navigator Tool setara web (lihat PlottingLayer.tsx, SurveyorPanel.tsx,
useSurveyStore.ts):
- Tap peta menambah titik; drag titik memindahkannya; tekan-tahan 350 ms lalu geser menarik
  handle Bezier (getaran ringan saat mode lengkung aktif); tap titik menampilkan knob handle
- Mode Curve / Straight, snap sudut Free/15°/45°/90°, tombol sudut per titik dan "Corners"
- Garis digambar dengan buildSurveyLine (Bezier), label jarak di segmentMidpoints, jarak
  Vincenty, azimuth, slope; panel bottom sheet daftar titik (DD, DMS, UTM, elevasi)
- Banyak sheet per survei, simpan/muat survei ke tabel surveys (format JSON sama dengan web,
  termasuk corner dan handle), sehingga survei yang dibuat di web terbuka sama di aplikasi
  dan sebaliknya
- Bekerja offline: simpan lokal (drift), sinkron saat online
```

**Selesai jika:** survei yang sama terlihat identik di web dan aplikasi; gesture tap / drag /
tahan-geser terasa natural di Android dan iPhone.

### Fase 6 — Rekam track & live tracking

**Prompt**

```text
Implementasikan rekam track (lihat TrackRecorder.md, TrackRecorderService.ts,
useTrackRecorderStore.ts) dan live tracking (Tracker.md, TrackerService.ts):
- Rekam terus saat layar mati / app di background: Android foreground service dengan
  notifikasi "Merekam track…", iOS background mode location
- Minta izin lokasi "Always" hanya saat user mulai merekam, dengan penjelasan sebelumnya
- Filter akurasi dan jarak minimum sama dengan web, simpan titik lokal dulu (drift), unggah
  ke recorded_tracks saat online; export GPX lewat share_plus
- Hormati aturan plan seperti web: Track Recorder merekam hanya Enterprise atau admin
  (canRecordTracks), semua akun login bisa melihat track sendiri & yang dibagikan, ganti nama
  track cloud Pro/Enterprise/admin; GPS Tracking broadcast Pro & Enterprise, "Record
  Activity" hanya Pro pengguna360; live monitor hanya Enterprise monitor360 atau admin
  (is_monitor())
- Teks izin lokasi dalam bahasa Indonesia dan Inggris
```

**Selesai jika:** rekam 30 menit dengan layar mati menghasilkan jalur utuh di kedua platform,
baterai wajar, GPX bisa dibuka di aplikasi lain.

### Fase 6b — S.O.S

**Prompt**

```text
Implementasikan S.O.S setara web (lihat src/components/SosButton.tsx, SosScreen.tsx,
SosAdminLayer.tsx, SosAlertsPanel.tsx, src/lib/sos.ts, src/lib/sosAlerts.ts, migration
20261024000014–16):
- Tombol S.O.S merah di peta hanya untuk akun can_use_sos (admin: di User Account), tahan
  3 detik (getar), hitung mundur 5 detik yang bisa dibatalkan
- Layar darurat: posisi DMS/desimal/UTM, elevasi, akurasi, baterai, jam; tombol telepon 112
  dan Basarnas 115, SMS ke kontak darurat (maks 5, disimpan di HP), share, sirine, senter
  berkedip pola Morse SOS; layar tetap menyala
- Laporan ke admin lewat RPC sos_report (client_id UUID per S.O.S, idempotent) saat mulai,
  tiap 30 detik, dan saat kirim pesan; antrean offline (drift) yang terkirim otomatis saat
  sinyal kembali, TERMASUK saat app di background (foreground service Android / background
  location iOS); "I'm safe" mengirim status resolved
- Admin: daftar S.O.S aktif & riwayat (admin_sos_alerts), lihat di peta, telepon/WhatsApp,
  resolve dengan catatan, hapus riwayat
- Push notification S.O.S ke semua admin: Supabase Database Webhook atau Edge Function pada
  INSERT sos_alerts yang mengirim FCM; simpan token perangkat admin di tabel baru (migration
  baru, kompatibel ke belakang). Ini fitur yang tidak bisa dilakukan versi web.
```

**Selesai jika:** S.O.S dari HP tanpa sinyal terkirim otomatis begitu sinyal kembali walau
layar mati; HP admin menerima notifikasi push dalam beberapa detik.

### Fase 7 — Offline maps, marked locations, export

**Prompt**

```text
- Offline maps dengan Mapbox TileStore / OfflineManager: pilih wilayah di peta, perkiraan
  ukuran, unduh dengan progres, daftar wilayah, hapus. Batas jumlah & ukuran per plan sama
  dengan web (check_offline_map_limits). Peta harus tetap tampil di mode pesawat.
- Marked Locations (tabel marked_locations) dengan ikon kategori yang sama dengan web, nama
  di atas marker, kartu ringkas yang dibuka/ditutup dengan tap marker; share ke akun lain
  (saran penerima Recent + cari nama/email) dan share sebagai link (Send to WhatsApp, Copy,
  Turn off)
- Marked Areas (tabel marked_areas, migration 0019): gambar polygon dengan tap sudut (Undo,
  Done), luas & keliling, warna garis, catatan, edit/redraw, hapus; mode FOKUS (mask gelap di
  luar area, fit ke area); share sebagai link
- Share Location dari tombol di peta: ambil satu posisi GPS, kirim ke WhatsApp (share_plus /
  wa.me), aplikasi lain, atau copy; format pesan sama dengan shareLocation.ts
- Buka link masuk (app_links): ?at= menampilkan pin "Shared location", ?place= menampilkan
  lokasi, ?area= membuka area dalam mode fokus, semuanya tanpa login; peta tidak boleh
  melompat ke GPS user saat dibuka dari link
- Export laporan PNG/JPG/PDF (snapshot Mapbox + paket pdf) dengan isi sama dengan web:
  titik survei bernomor per jalur, marked locations yang terlihat, tabel jarak per jalur,
  profil elevasi, ukuran file kecil (JPEG ~0,8), dibagikan lewat share_plus
- Basemap kustom: tampilkan basemap yang diunggah dari web (custom_basemaps + storage)
```

**Selesai jika:** wilayah offline terbuka di mode pesawat setelah aplikasi ditutup dan dibuka
lagi; link lokasi/area dari WhatsApp membuka aplikasi langsung di titik/area yang benar.

### Fase 8 — Kepatuhan store

**Prompt**

```text
Siapkan kepatuhan Google Play dan App Store:
- "Delete account" di User Account (konfirmasi dua langkah). Tambahkan endpoint di web
  (api/) yang menghapus akun pemanggil beserta datanya (foreign key sudah cascade sejak
  migration 20261024000010); admin tidak bisa menghapus dirinya sendiri. Tambahkan juga
  halaman web publik /delete-account (dibutuhkan Google Play)
- Tidak ada harga atau tombol beli plan di aplikasi (plan tetap diatur admin); jika nanti
  menjual plan di aplikasi, wajib In-App Purchase / Play Billing
- Tanpa iklan di aplikasi v1 (iklan web Monetag tidak dipakai); jika perlu, AdMob resmi
- iOS privacy manifest (PrivacyInfo.xcprivacy), teks izin di Info.plist (lokasi, motion
  untuk kompas, notifikasi), background mode location; Android permission
  ACCESS_BACKGROUND_LOCATION + FOREGROUND_SERVICE_LOCATION + POST_NOTIFICATIONS + CALL_PHONE
  hanya bila perlu (tel: tidak membutuhkannya)
- Universal links / App Links: tambahkan apple-app-site-association dan
  .well-known/assetlinks.json di web (public/.well-known/), lalu entitlement associated
  domains di iOS dan intent-filter autoVerify di Android
- Halaman tentang aplikasi: versi, link privacy, terms, reviews, dukungan
```

**Selesai jika:** user bisa menghapus akunnya sendiri dari aplikasi; semua teks izin dan
halaman legal tersedia.

### Fase 9 — Pengujian & performa

**Prompt**

```text
Buat docs/mobile-test-checklist.md dan jalankan di HP fisik (minimal satu Android menengah
dan satu iPhone):
- Akun, peta 2D/3D, kompas (putar HP mendatar, peta diputar, kalibrasi), Navigator Tool
  (semua gesture), rekam track layar mati, live tracking, offline map mode pesawat, marked
  locations & areas (gambar, fokus, link), Share Location, link masuk dari WhatsApp, S.O.S
  (tanpa sinyal, layar mati, push ke admin), export, share aplikasi, cuaca
- Ukur dengan Flutter DevTools (frame time), Android Studio Profiler, Xcode Instruments
  (Energy, GPU): tidak ada render terus-menerus saat peta diam
- Perangkat lama (Android 10, iOS minimum yang didukung), layar kecil dan tablet
- Integration test (integration_test) untuk alur login → buat survei → simpan
Siapkan akun demo Pro untuk reviewer store, berisi survei, track, dan wilayah offline contoh.
```

**Selesai jika:** semua item checklist lulus; tidak ada crash di Sentry/Crashlytics selama
uji internal.

### Fase 10 — Build rilis & pengajuan

**Prompt**

```text
Siapkan rilis:
- Android: keystore upload (di luar repo, password di password manager), Play App Signing,
  `flutter build appbundle --flavor prod`, versionCode/versionName dari pubspec.yaml
- iOS: signing di Xcode, `flutter build ipa --flavor prod`, upload ke App Store Connect
- Codemagic atau GitHub Actions + Fastlane untuk build dan upload ke Internal testing (Play)
  dan TestFlight; secret (keystore, sertifikat, Mapbox downloads token, dart-define) disimpan
  di secret CI
- docs/release.md: langkah rilis, penomoran versi, cara rollback (halt rollout)
Jangan commit keystore, sertifikat, token, atau file dart-define production.
```

**Selesai jika:** build masuk Internal testing Play Console dan TestFlight, bisa diinstal tester.

---

## 5. Checklist Google Play

- [ ] Akun Google Play Console (biaya pendaftaran satu kali). Akun pribadi baru wajib
      **closed testing** dengan sejumlah tester selama beberapa hari sebelum production
      (cek angka terbaru di Play Console)
- [ ] Target **API level terbaru yang diwajibkan** Google saat pengajuan
- [ ] AAB ditandatangani, Play App Signing aktif
- [ ] Store listing (ID + EN): nama, deskripsi pendek & panjang, ikon 512×512, feature graphic
      1024×500, screenshot HP (dan tablet bila didukung)
- [ ] **Data safety form**: lokasi presisi & background, email, nama, nomor HP, organisasi,
      konten buatan user (track, survei, lokasi, area), laporan S.O.S (lokasi, pesan, baterai
      dikirim ke admin), tujuan pemakaian, apakah dibagikan (link share bisa dibuka siapa
      saja yang menerimanya). Kontak darurat S.O.S hanya disimpan di HP
- [ ] **Deklarasi izin lokasi background** + video singkat fitur rekam track
- [ ] Foreground service type `location` dideklarasikan
- [ ] Content rating, target audience (bukan untuk anak-anak), ads declaration
- [ ] Privacy policy: `https://landscape360.jcdigital.co.id/privacy`
- [ ] Link hapus akun: `https://landscape360.jcdigital.co.id/delete-account`
- [ ] Akses reviewer: akun demo + instruksi
- [ ] Rilis bertahap: Internal → Closed → Production (staged rollout)

## 6. Checklist App Store

- [ ] Apple Developer Program (biaya tahunan), bundle ID `id.co.jcdigital.landscape360`
- [ ] App Store Connect (ID + EN): nama, subtitle, kata kunci, deskripsi, kategori
      **Navigation** (sekunder: Sports / Travel)
- [ ] Screenshot untuk ukuran layar iPhone yang diwajibkan (dan iPad bila didukung)
- [ ] **App Privacy (nutrition label)** dan privacy manifest
- [ ] Teks izin: `NSLocationWhenInUseUsageDescription`,
      `NSLocationAlwaysAndWhenInUseUsageDescription`, foto/file bila diperlukan
- [ ] Background mode **Location updates** dengan alasan jelas di catatan review
- [ ] Hapus akun di dalam aplikasi (guideline 5.1.1(v))
- [ ] Tidak ada pembelian digital di luar IAP (guideline 3.1.1)
- [ ] Catatan reviewer: akun demo, cara mencoba rekam track dan offline map
- [ ] TestFlight internal → eksternal → submit review → phased release

## 7. Aset & teks yang perlu disiapkan (non-teknis)

- Ikon final 1024×1024 (tanpa transparansi untuk iOS), splash screen
- 5–8 screenshot per platform: peta 3D, Navigator Tool (garis lengkung & siku), rekam track,
  Marked Area mode fokus, kompas di titik lokasi, layar S.O.S, offline map
- Deskripsi untuk **penggiat alam terbuka** dengan tagline "Explore without Limits":
  navigasi digital, rencana jalur, rekam perjalanan, peta offline untuk area tanpa sinyal,
  S.O.S, berbagi lokasi lewat WhatsApp
- Email dukungan contact@jcdigital.co.id, URL dukungan, privasi, hapus akun
- Akun demo reviewer (khusus review, password disimpan aman)

## 8. Risiko utama

| Risiko | Dampak | Mitigasi |
|---|---|---|
| Dua codebase (web + Flutter) | Fitur dan bug harus dikerjakan dua kali | Batasi cakupan app v1; admin tetap web; logika di-port dengan test yang sama |
| Hasil hitung beda antara web dan app | Jarak/azimuth survei tidak cocok | Port surveyUtils dengan test pembanding (Fase 2); format JSON survei identik |
| Biaya Mapbox mobile | Tagihan naik seiring pengguna | Pantau usage, batasi zoom unduhan offline, siapkan opsi MapLibre |
| Izin lokasi background ditolak store | Rekam track di background tidak boleh | Minta "Always" hanya saat merekam, deklarasi + video jelas |
| Lisensi plugin background GPS | Biaya tambahan (Transistorsoft untuk rilis Android) | Bandingkan dengan plugin gratis di Fase 0, uji keduanya di HP fisik |
| GeoTIFF/GeoPDF tidak ada library Dart | Basemap kustom tidak bisa dibuat di app | v1: unggah dari web, app hanya menampilkan |
| S.O.S tidak terkirim saat darurat | Keselamatan pengguna | Antrean offline + kirim di background; SMS & telepon tetap sebagai jalur utama; uji di area tanpa sinyal; jelaskan di aplikasi bahwa S.O.S ke admin butuh data |
| Kompas tidak akurat | Arah jarum salah | Tampilkan petunjuk kalibrasi; sembunyikan jarum saat platform melaporkan kompas tidak terkalibrasi |
| Link share dibuka tanpa aplikasi | Pengguna lain tidak bisa melihat | Link tetap bekerja di web; aplikasi hanya mengambil alih bila terpasang |
| Perubahan skema Supabase dari sisi web | App versi lama rusak | Perubahan skema selalu kompatibel ke belakang; tambah kolom, jangan ubah/hapus kolom yang dipakai app |
