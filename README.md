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
| 6 Track Recorder | Selesai: rekam di HP dulu (SQLite) saat layar mati / di background, Online / Offline, pause / resume, pulih setelah app ditutup, sinkron ke `recorded_tracks`, daftar track sendiri + dibagikan, berbagi via email, GPX. Live tracking ditahan (kanal `tracking-room` publik). Menunggu uji di HP |
| 6b–10 | Belum |

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
