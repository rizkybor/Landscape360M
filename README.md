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
| 3 Akun | Kode + test selesai; perlu uji dengan data production (`docs/mobile-test-checklist.md`) |
| 4–10 | Belum |

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
