# Landscape 360 — aplikasi Flutter (Android / iPhone)

Explore without Limits. Aplikasi native Landscape 360, memakai backend yang sama dengan web
(`../Landscape360`): Supabase + Vercel Functions. Rencana kerja per fase ada di `Task.md`,
spesifikasi di `docs/flutter-spec.md`.

## Status

| Fase | Status |
|---|---|
| 0 Spesifikasi | `docs/flutter-spec.md` (perlu persetujuan, lihat pertanyaan Q1–Q22) |
| 1 Fondasi | Selesai untuk Android (flavor dev/prod, tema, font Inter, router, CI). iOS flavor menunggu Xcode |
| 2 Port logika | Selesai: `lib/domain`, dibandingkan dengan output web asli |
| 3 Akun | Selesai, lulus uji di iPhone dengan akun production |
| 4 Peta | Selesai: 4a (peta, 2D/3D, lokasi, telemetry, sheet), 4b (jarum kompas, kontur, grid DMS), 4c (cuaca BMKG, pencarian, route planner). Menunggu uji di HP |
| 5 Navigator | Selesai: titik, lengkung Bezier, sudut tajam, Straight + snap sudut, banyak sheet, daftar titik (DD/DMS/UTM/Elev, azimuth, slope), simpan otomatis ke cloud (format sama dengan web) + offline. Menunggu uji di HP |
| 6 Track Recorder | Selesai: rekam di HP dulu (SQLite) saat layar mati / di background, Online / Offline, pause / resume, pulih setelah app ditutup, sinkron ke `recorded_tracks`, daftar track sendiri + dibagikan, berbagi via email, GPX. Menunggu uji di HP |
| 6b S.O.S | Selesai tanpa push: tombol tahan 3 dtk, hitung mundur, layar darurat (DMS/UTM, 112/115, SMS kontak, share, sirene, senter Morse), laporan ke admin tiap 30 dtk lewat antrean offline yang jalan juga di background, panel admin (banner, penanda peta, resolve, hapus). Push notification menunggu Firebase + Apple Developer berbayar. Menunggu uji di HP |
| 7a POIs, Share Location, link | Selesai: layer POI (warna per kategori, cluster, kartu), tombol POIs diingat, Share Location (WhatsApp / aplikasi lain / copy), penanganan link `?at=` dan `?place=` tanpa login. Link dari luar aplikasi menunggu Fase 8 (domain terverifikasi). Menunggu uji di HP |
| 7b Marked Locations | Selesai: penanda ikon kategori + nama, kartu, daftar Mine/Shared/All, cari, tambah/edit (pilih di peta, pusat peta, GPS), hapus, GPX, berbagi ke akun (Recent + cari) dan sebagai link. Menunggu uji di HP |
| 7c Marked Areas | Selesai: gambar poligon (Undo, Done), luas & keliling, warna, catatan, edit/redraw, hapus, mode fokus (masker gelap, fit ke area), share link `?area=` (dibuka tanpa login). Menunggu uji di HP |
| 7d Peta offline | Selesai: pilih area dengan bingkai, perkiraan ukuran dan batas plan sama dengan web, unduh dengan progres (Mapbox TileStore: style, tile, elevasi), daftar, unduh ulang di HP lain, hapus. Diuji di simulator tanpa jaringan. Menunggu uji di HP |
| 7e Basemap kustom | Selesai: daftar basemap Enterprise dari web, nyala/mati (tersinkron), opacity, zoom, hapus; gambar disimpan di HP sehingga tampil tanpa sinyal. Unggah tetap di web. Menunggu uji di HP |
| 7f Ekspor laporan | Selesai: PNG / JPG / PDF seperti web (header, peta + titik bernomor, info peta, tabel titik, profil elevasi, marked locations terlihat, footer halaman), dibagikan lewat lembar berbagi. Menunggu uji di HP |
| 7g GPS Tracking | Selesai di app: anggota (pengguna360) Pro / Enterprise membagikan posisi live ke monitor lewat kanal privat, tiap 3 dtk, juga saat layar mati; menjawab permintaan monitor; kirim ulang saat sinyal kembali. Monitor360 dan admin memantau di web. Aktif setelah migration + perubahan web di `docs/backend/live-tracking/` diterapkan. Menunggu uji di HP |
| 8 Kepatuhan store | Selesai di app: hapus akun (dua langkah + password, data akun di HP ikut dihapus, admin tidak bisa), halaman About (versi, privasi, syarat, hapus akun, dukungan), privacy manifest iOS, teks izin (lokasi, simpan ke Foto), notifikasi Android 13, App Links Android dan Associated Domains iOS (build Release). Bagian web siap disalin dari `docs/backend/store/` (endpoint `DELETE /api/account`, halaman `/delete-account`, `.well-known`, revisi Privacy Policy). Tanpa harga, pembelian, atau iklan di app. Menunggu uji di HP |
| 8–10 | Belum |

## Menjalankan

```sh
cp config/dev.json.example config/dev.json   # isi URL + anon key + Mapbox pk. token
flutter run --flavor dev --dart-define-from-file=config/dev.json
```

`config/*.json` tidak di-commit. Jangan pernah mengisi service role key: aplikasi akan
menolak start (lihat `docs/security.md`).

## Test

```sh
flutter analyze
flutter test
```

`test/domain/web_parity_test.dart` membandingkan hasil Dart dengan nilai yang dihitung oleh
kode TypeScript web (`test/fixtures/web_reference.json`, minimal 6 desimal). Setelah logika
web berubah, buat ulang fixture-nya:

```sh
WEB_REPO=../Landscape360 tool/web_reference/generate.sh && flutter test
```

## Struktur

- `lib/core`: config, tema, router, provider
- `lib/data`: Supabase, API `/api/*`, repository
- `lib/domain`: logika murni hasil port dari web (tanpa Flutter UI)
- `lib/features/<fitur>`: layar
