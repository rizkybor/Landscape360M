# Landscape 360 — Spesifikasi Aplikasi Flutter (Fase 0)

Status: **draf untuk disetujui pemilik** · Disusun 28 Oktober 2026

Acuan: repo web `../Landscape360` (READ ONLY) pada commit `2d9f507` (27-10-2026, v3.3.0,
`package.json`). Semua path di bawah relatif terhadap repo web kecuali disebut lain.
Sumber kebenaran skema adalah `supabase/migrations/*.sql`; bila dokumen (`ARCHITECTURE.md`,
`Tracker.md`) bertentangan dengan SQL, SQL yang dipakai.

> Catatan penting: urutan migration tidak linier (mis. policy `profiles` di
> `20240101000002_*` dibuat sebelum tabelnya di `20260202000000_*`), dan ada migration seed
> yang tidak idempoten. Sebelum Fase 1, ambil skema production yang sebenarnya
> (`supabase db dump --schema public` + daftar policy `storage.objects`) dan cocokkan dengan
> dokumen ini. Lihat bagian 6, pertanyaan Q1.

Daftar isi:
1. Keputusan fitur
2. Kontrak backend (tabel, RPC, RLS, storage, /api, realtime, gerbang plan/role)
3. Model data Dart
4. Logika yang di-port + file test acuan
5. Keamanan
6. Risiko & pertanyaan untuk pemilik
7. Hal di `Task.md` yang tidak sesuai dengan kode web

---

## 1. Keputusan fitur

Aturan dari `Task.md` §2: v1 = fitur lapangan + akun; panel admin tetap di web, kecuali
admin **menerima push S.O.S** dan **melihat/resolve/hapus S.O.S**; basemap kustom hanya
ditampilkan di aplikasi.

Legenda: **v1** = app v1 · **nanti** = app nanti · **web** = web saja.

### 1.1 Peta & tampilan

| Fitur web | Sumber web | Keputusan | Catatan untuk app |
|---|---|---|---|
| Peta 2D / 3D terrain, exaggeration | `components/MapBoxContainer.tsx`, `store/useMapStore.ts` | v1 | `mapbox_maps_flutter`, nilai default exaggeration diambil dari `useMapStore.ts` |
| Style Streets / Outdoors / Satellite | `RegionDrawingOverlay.tsx:215-222` (style yang dipakai: `streets-v12`, `outdoors-v12`, `satellite-streets-v12`) | v1 | |
| Kontur (interval, opacity) | `ContourLayer.tsx`, `utils/TurfContourProvider.ts` (kontur dihitung di klien dari DEM) | v1 | Usul: pakai layer kontur `mapbox-terrain-v2` di SDK; hasil visual bisa beda dari web (lihat Q14) |
| Grid DMS | `GridDMSLayer.tsx` | v1 | Port perhitungan garis grid |
| Kompas, pitch, bearing, zoom | `NavigationControls.tsx` | v1 | |
| Telemetry koordinat DD/DMS, elevasi, slope | `NavigationControls.tsx`, `utils/elevationUtils.ts` | v1 | Elevasi lewat `queryTerrainElevation` SDK; `decodeTerrainRgb` hanya cadangan |
| "Drag to: Move the map / Look around" | `ControlPanel.tsx` | **web** | Khusus desktop |
| Titik lokasi + jarum kompas (beam 70°, abaikan < 1,5°) + petunjuk kalibrasi | `UserLocationMarker.tsx:7,198`, `lib/deviceHeading.ts` | v1 | Sensor native; logika kualitas kompas di-port |
| Objek 3D three.js di atas peta | `ThreeScene.tsx` | nanti | Tidak ada padanan langsung di SDK mobile |
| Pencarian lokasi (Mapbox Geocoding v5 + POI) | `SearchPanel.tsx:150` | v1 | |
| Cuaca BMKG | `WeatherWidget.tsx:73` (`api.bmkg.go.id/publik/prakiraan-cuaca?adm4=<DEFAULT_ADM4>`, lokasi tetap "Jakarta Pusat") | v1 | Sama dengan web (adm4 tetap); lihat Q15 |
| Route planner (driving tol / tanpa tol / walking) | `store/useRouteStore.ts:40-49` (Mapbox Directions v5, `exclude=toll`) | v1 | |
| Points of Interest (tampil) | `lib/pointsOfInterest.ts`, tabel `points_of_interest` | v1 | Bisa dibaca tanpa login; fallback `BUNDLED_POIS` (`src/data/myDataLocation.json`) |
| Kelola POI | `PoiManagerPanel.tsx` | **web** | Admin |
| Guide / Get Started | `ControlPanel.tsx` (`showGetStarted`) | v1 | |
| Share aplikasi (link situs ke WhatsApp/copy) | `AppShareButton.tsx` | v1 | |
| Share Location (posisi saat ini, bukan live) | `ShareLocationButton.tsx`, `lib/shareLocation.ts` | v1 | |
| Export laporan PNG/JPG/PDF | `ScreenshotControl.tsx` (saat ini di-comment di `MapDashboard.tsx:4`), export di panel Navigator | v1 (Fase 7) | Lihat Q16: apakah benar masuk v1 |
| Footer Docs / Reviews / FAQ / Terms / Privacy | `DocsPage.tsx`, `ReviewsPage.tsx`, `FaqPage.tsx`, `TermsPage.tsx`, `PrivacyPage.tsx` | **web** | Dibuka di browser (`url_launcher`) |
| Menulis review | `lib/reviews.ts`, RPC `submit_review` | nanti | Bisa ditambah kemudian (RPC sudah ada) |
| PWA / service worker / SEO / iklan Monetag | `sw.ts`, `SEO.tsx` | **web** | Tanpa iklan di app v1 |

### 1.2 Navigator Tool (survei)

| Fitur | Sumber | Keputusan |
|---|---|---|
| Tap tambah titik, drag pindah, tahan-geser handle Bezier, sudut smooth/sharp per titik, "Corners" | `PlottingLayer.tsx`, `SurveyorPanel.tsx`, `store/useSurveyStore.ts` | v1 |
| Mode Straight + snap Free/15°/45°/90° | `useSurveyStore.ts` (`ANGLE_STEPS`), `surveyUtils.ts:snapToAngle` | v1 |
| Banyak sheet (group) per survei | `useSurveyStore.ts` | v1 |
| Jarak & azimuth Vincenty, slope, label jarak per segmen | `utils/surveyUtils.ts` | v1 |
| Simpan / muat / hapus survei di cloud (`surveys`) | `useSurveyStore.ts:217-440` | v1 (+ simpan lokal `drift`) |
| Batas jumlah survei Free 2 / Pro 4 / Enterprise 10 | `useSurveyStore.ts:343-361` (**hanya di klien**) | v1, sama dengan web |

### 1.3 Rekam track & live tracking

| Fitur | Sumber | Keputusan |
|---|---|---|
| Track Recorder: rekam (Enterprise/admin), pause/resume, statistik, local-first | `store/useTrackRecorderStore.ts`, `services/TrackRecorderService.ts`, `utils/trackRecorderGeo.ts`, `TrackRecorder.md` | v1 (background GPS) |
| Lihat track sendiri & yang dibagikan (semua akun login) | `services/trackRecorderSync.ts` | v1 |
| Upload/sinkron ke `recorded_tracks`, rename cloud (Pro/Ent/admin) | `trackRecorderSync.ts`, RPC `rename_recorded_track` | v1 |
| Share track ke akun lain via email (Enterprise/admin) | RPC `share_recorded_track` | v1 |
| Export GPX | `trackRecorderGeo.ts:buildGpx` | v1 |
| Live tracking: broadcast posisi (Pro/Enterprise) | `services/TrackerService.ts`, `ControlPanel.tsx:831-870` | **v1 bersyarat** (lihat Q4 & temuan S1) |
| "Record Activity" (`tracker_activity_sessions` + `tracker_logs`, hanya `pengguna360` Pro) | `TrackerService.ts`, `ControlPanel.tsx:251-254` | v1 bersyarat (Q4) |
| Monitor live (Enterprise `monitor360`/admin) | `TrackerService.ts:615-680`, `LiveTrackerLayer.tsx` | v1 bersyarat (Q4) |
| Riwayat aktivitas & GPX dari `tracker_logs` | `TrackerHistoryViewer.tsx` | nanti |
| Mode simulasi tracker | `TrackerService.ts:690-720` | **web** (alat demo) |

### 1.4 Marked Locations, Marked Areas, offline, basemap

| Fitur | Sumber | Keputusan |
|---|---|---|
| Marked Locations CRUD, 10 kategori + ikon, batas plan | `services/markedLocationSync.ts`, `utils/markedLocations.ts`, `utils/markedLocationIcons.ts` | v1 |
| Share ke akun (saran penerima, cari nama/email) | RPC `share_marked_locations`, `marked_location_share_suggestions` | v1 |
| Share sebagai link `?place=` | RPC `create/get/revoke_marked_location_link` | v1 |
| Buka link `?place=` tanpa login | RPC `open_marked_location_link` | v1 |
| Export GPX waypoint | `markedLocations.ts:toGpx` | v1 |
| Admin: lihat/edit lokasi semua akun | RPC `admin_list_marked_locations` | **web** |
| Marked Areas: gambar polygon, luas/keliling, warna, catatan, edit, hapus, mode FOKUS | `services/markedAreaSync.ts`, `utils/markedAreas.ts`, `MarkedAreaPanel.tsx`, `MarkedAreaLayer.tsx` | v1 |
| Link area `?area=` (buat/cabut, buka tanpa login → mode fokus) | RPC `*_marked_area_link`, `SharedAreaLayer.tsx` | v1 |
| Offline maps (pilih wilayah, estimasi, unduh, daftar, hapus, batas plan) | `RegionDrawingOverlay.tsx`, `OfflineManager.tsx`, `utils/tileUtils.ts`, tabel `offline_maps` | v1 (Mapbox TileStore; tile web di IndexedDB tidak dipakai) |
| Basemap kustom: tampilkan, aktif/nonaktif, opacity | `store/useCustomBasemapStore.ts:136-175,559-585` | v1 (display only) |
| Basemap kustom: upload GeoTIFF/GeoPDF, georeference, hapus | `useCustomBasemapStore.ts:176-540`, `GeoreferenceTool.tsx`, `BasemapManager.tsx` | **web** |
| Pemakaian cloud storage | RPC `my_storage_usage`, `lib/storageUsage.ts` | v1 |

### 1.5 Akun

| Fitur | Sumber | Keputusan |
|---|---|---|
| Login email + password, logout | `AuthControl.tsx:266-330` | v1 |
| `record_login` setelah login, `record_logout` sebelum signOut | `lib/loginHistory.ts` | v1 |
| Request account (form publik) | `lib/accountRequests.ts:63`, `POST /api/account-requests` | v1 |
| Lupa password = buka email ke admin (`mailto:contact@jcdigital.co.id`) | `AuthControl.tsx:252-264` | v1 |
| Ganti password sendiri | `lib/accountPassword.ts`, `ChangePasswordForm.tsx` | v1 |
| Edit profil: `display_name` (auth metadata) + organization/phone (`update_my_contact`) | `AuthControl.tsx:208-240`, `lib/profileContact.ts` | v1 |
| Badge plan/role, `is_admin`, `can_use_sos` (disimpan lokal untuk offline) | `useSurveyStore.ts:142-215` | v1 |
| Hapus akun sendiri | **belum ada** di web | v1 (wajib store; perlu endpoint baru, Fase 8) |
| Tombol "Buka panel admin di web" untuk admin | — | v1 |

### 1.6 S.O.S

| Fitur | Sumber | Keputusan |
|---|---|---|
| Tombol S.O.S (tahan 3 s, hitung mundur 5 s), hanya `can_use_sos`; admin lewat User Account (tombol peta disembunyikan untuk admin) | `SosButton.tsx:7,15,62` | v1 |
| Layar darurat (DMS/desimal/UTM, elevasi, akurasi, baterai), 112/115, SMS kontak darurat (maks 5, lokal per akun), sirine, lampu Morse | `SosScreen.tsx`, `lib/sos.ts` | v1 (senter asli, wakelock) |
| Laporan `sos_report` saat mulai, tiap 30 s, saat kirim pesan; outbox offline; "I'm safe" = `resolved` | `SosScreen.tsx:20,107-130,252`, `lib/sosAlerts.ts` | v1 (+ kirim di background) |
| Admin: banner/marker S.O.S aktif (polling 30 s), riwayat, resolve dengan catatan, hapus yang resolved | `SosAdminLayer.tsx:8`, `SosAlertsPanel.tsx:44`, RPC `admin_sos_alerts`, `admin_resolve_sos`, `admin_delete_sos` | v1 (pengecualian admin) |
| Push notification S.O.S ke admin | **belum ada** | v1 (perlu migration + Edge Function/Webhook baru; Q3) |

### 1.7 Admin (semua web saja)

Manage Users (`UserManagementPanel.tsx`, `/api/admin-users`), izin S.O.S per akun, batas
storage plan/akun, Account Requests + badge notifikasi (`AccountRequestsPanel.tsx`,
`services/useAccountRequestAlerts.ts`), User Activity & login history
(`AdminActivityFeed.tsx`, `UserLoginHistory.tsx`), Broadcast via Gmail
(`BroadcastComposer.tsx`, `lib/adminEmail.ts`), email ke user (`UserEmailComposer.tsx`),
kelola POI, moderasi review (`admin_reply_review`, `admin_set_review_hidden`), daftar marked
locations semua akun → **web**.

---

## 2. Kontrak backend

Basis: Supabase project yang sama (URL + anon key dari `VITE_SUPABASE_URL` /
`VITE_SUPABASE_ANON_KEY`, `src/lib/supabaseClient.ts`) dan Vercel Functions di
`https://landscape360.jcdigital.co.id/api/*` (`vercel.json` tidak me-rewrite `api/`).

Konvensi: kolom `timestamptz` dikirim/diterima sebagai string ISO-8601; `uuid` sebagai
string; `bigint` bisa datang sebagai `int` (Dart `int` aman). RPC yang `RETURNS TABLE`
selalu mengembalikan **array** (web mengambil `data[0]`). RPC `RETURNS TEXT/UUID` mengembalikan
skalar JSON. Error PostgREST: `PostgrestException.message` berisi teks `RAISE EXCEPTION`
apa adanya (web menampilkannya langsung).

### 2.1 Fungsi pembantu peran (dipakai RLS, bukan dipanggil app)

| Fungsi | Benar jika | File |
|---|---|---|
| `is_admin()` | `profiles.is_admin` untuk `auth.uid()` | `20261024000003_create_marked_locations.sql:13`, `20261024000007_reviews.sql` |
| `is_monitor()` | `is_admin` **atau** (`status_user='monitor360'` dan `status_subscribe='Enterprise'`) | `20261023000000_restrict_profile_self_update.sql:24-41` |
| `can_use_track_recorder()` | `is_admin` atau `status_subscribe='Enterprise'` | `20261024000001_track_recorder_sharing.sql:6-19` |
| `can_share_marked_locations()` | `is_admin` atau plan `Pro`/`Enterprise` (dipakai juga untuk link area) | `20261024000003:41-53` |
| `can_upload_custom_basemaps()` | `is_admin` atau `Enterprise` (semua role) | `20261024000013_basemaps_all_enterprise.sql` |
| `can_use_sos()` | `is_admin` atau `can_use_sos` | `20261024000015_sos_alerts.sql` |
| `marked_location_limit(uid)` | admin NULL, Ent 1000, Pro 100, lainnya 10 | `20261024000003:24-38` |
| `marked_area_limit(uid)` | admin NULL, Ent 20, Pro 10, lainnya 5 | `20261026000019_marked_areas.sql` |
| `storage_limit_bytes(uid)` | admin NULL; `storage_limit_mb` override → `plan_storage_limits` → Free → 10 MB | `20261024000004_storage_quotas.sql` |

Hanya **satu** akun admin yang bisa ada (`UNIQUE INDEX profiles_single_admin`,
`20261023000000:14-17`).

### 2.2 Tabel yang dipakai app

Untuk tiap tabel: kolom (tipe, null?, default), RLS, trigger, operasi yang dipakai app.

#### `profiles`
Kolom: `id uuid PK → auth.users ON DELETE CASCADE`, `email text`, `status_subscribe text
default 'Free' CHECK IN ('Free','Pro','Enterprise')`, `status_user text default
'pengguna360'`, `created_at timestamptz`, `updated_at timestamptz`, `is_admin bool NOT NULL
default false`, `storage_limit_mb numeric NULL (>=0)`, `organization text NULL (≤120)`,
`phone text NULL (≤30)`, `can_use_sos bool NOT NULL default false`.
(`20260202000000_create_profiles_table.sql`, `20240218_fix_constraint_and_create_user.sql:5-8`,
`20240218_add_status_user.sql`, `20261023000000`, `20261024000004:62`, `20261024000009`,
`20261024000014`). `status_user` tidak punya CHECK di SQL; nilai valid hanya `pengguna360` /
`monitor360` (`api/admin-users.ts:24`).

RLS: SELECT milik sendiri (`Users can view own profile`, `Users can view their own profile`)
**dan** SELECT semua baris untuk `is_monitor()` (`20240222_fix_tracker_policies.sql:53-58`).
Tidak ada policy INSERT/UPDATE/DELETE untuk klien sejak `20261023000000:5` (baris dibuat trigger
`handle_new_user`, diubah lewat service role di `/api/*` atau RPC `update_my_contact`).

App: `select('id,email,status_subscribe,status_user,is_admin,can_use_sos,organization,phone,storage_limit_mb').eq('id', uid).maybeSingle()`.
Web memuat terpisah agar kolom yang belum ada tidak memecah login (`useSurveyStore.ts:153-201`);
app boleh satu query asalkan semua migration sudah jalan (Q1). Jika `is_admin` → anggap
plan `Enterprise`, role `monitor360`, `canUseSos=true` (`useSurveyStore.ts:166-174`).
Nama tampilan **bukan** di `profiles`: ambil dari `auth.currentUser.userMetadata`
`display_name` → `full_name` → `name` (`lib/profileContact.ts:7-10`).

#### `surveys`
Kolom: `id uuid PK default gen_random_uuid()`, `user_id uuid NOT NULL → auth.users ON DELETE
CASCADE`, `name text default 'Untitled Survey'`, `data jsonb default '[]'`, `created_at`,
`updated_at` (diisi klien, tanpa trigger) (`20240601000000_create_surveys_table.sql`,
`20261024000010_cascade_user_delete.sql`).
RLS: SELECT/INSERT/UPDATE/DELETE hanya `auth.uid() = user_id`.
Trigger: `surveys_storage_quota` (BEFORE INSERT/UPDATE, `assert_storage_quota`, error
`HINT 'storage_quota'`, `20261024000004`).
App: list `select('id,name,updated_at').eq('user_id',uid).order('updated_at',desc)`; muat
`select('*').eq('id',id).single()`; simpan `insert({user_id,data,name,updated_at}).select()`
atau `update(...).eq('id',id).select()`; hapus `delete().eq('id',id).eq('user_id',uid)`
(`useSurveyStore.ts`). Format `data` lihat §3.1.

#### `recorded_tracks`
Kolom (`20261024000000_create_recorded_tracks.sql`): `id uuid PK` (**tanpa default**, dibuat
klien), `user_id uuid NOT NULL`, `name text NOT NULL (1–120)`, `mode text IN
('online','offline')`, `status text IN ('recording','paused','completed')`, `started_at
timestamptz NOT NULL`, `ended_at timestamptz NULL`, `elapsed_ms bigint default 0`,
`distance_m float8 default 0`, `moving_time_ms bigint default 0`, `elevation_gain_m float8`,
`elevation_loss_m float8`, `max_alt_m float8 NULL`, `min_alt_m float8 NULL`, `point_count int`,
`points jsonb default '[]'` (array `[lng, lat, alt|null, timestamp_ms, accuracy_m, segment]`),
`created_at`, `updated_at`.
RLS: SELECT milik sendiri **atau** dibagikan ke saya (`20261024000001:83-94`); INSERT/UPDATE
hanya milik sendiri **dan** `can_use_track_recorder()`; DELETE milik sendiri.
Trigger: `recorded_tracks_storage_quota`.
App: upsert seluruh track `upsert({...row, points}, onConflict:'id')`; list metadata
(kolom `METADATA_COLUMNS`, `trackRecorderSync.ts:31-32`); ambil `points` per id; delete per id.

#### `recorded_track_shares`
`track_id uuid → recorded_tracks ON DELETE CASCADE`, `owner_id uuid`, `shared_with uuid`,
`created_at`, `PK (track_id, shared_with)`, `CHECK owner_id <> shared_with`.
RLS: SELECT/DELETE jika owner atau penerima; INSERT owner + `can_use_track_recorder()` (app
memakai RPC). App: hapus share `delete().eq('track_id',t).eq('shared_with',u)` (pemilik
mencabut / penerima keluar).

#### `marked_locations`
Kolom (`20261024000003:84-100`): `id uuid PK default gen_random_uuid()`, `user_id uuid NOT
NULL default auth.uid()`, `name text (trim 1–120)`, `category text default 'poi' IN
('poi','camp','summit','water','shelter','viewpoint','trailhead','hazard','cave','parking')`,
`lng float8 (-180..180)`, `lat float8 (-90..90)`, `elevation_m float8 NULL`, `description
text NULL (≤2000)`, `address text NULL (≤200)`, `contact text NULL (≤120)`, `tags text[] NOT
NULL default '{}' (≤10 item)`, `created_at`, `updated_at`.
RLS: SELECT milik sendiri, admin, atau dibagikan; INSERT `user_id = auth.uid()`; UPDATE/DELETE
milik sendiri atau admin. Trigger: batas plan (BEFORE INSERT, pesan `You have reached the
maximum of % marked locations for your plan.`), `touch_marked_location` (kunci `user_id`,
`created_at`, set `updated_at`), storage quota.
App: kolom `COLUMNS` (`markedLocationSync.ts:30-31`); insert tanpa `user_id` (default);
update/delete per `id`.

#### `marked_location_shares`
`location_id uuid → marked_locations CASCADE`, `owner_id`, `shared_with`, `created_at`, PK
`(location_id, shared_with)`. RLS: SELECT/DELETE owner atau penerima; INSERT hanya lewat RPC.

#### `marked_location_links`
`token text PK CHECK ~ '^[0-9a-f]{32}$'`, `location_id uuid CASCADE`, `owner_id`,
`created_at`, `revoked_at NULL`. RLS: SELECT milik sendiri; tulis hanya lewat RPC
(`20261026000018_marked_location_links.sql`).

#### `marked_areas`
Kolom (`20261026000019:13-25`): `id uuid PK default`, `user_id uuid default auth.uid()`,
`name text (trim 1–120)`, `color text default '#d49b22' CHECK ~ '^#[0-9a-fA-F]{6}$'`, `notes
text NULL (≤2000)`, `ring jsonb NOT NULL` (array 3–500 elemen `[lng, lat]`, **tidak ditutup**),
`area_m2 float8 >= 0`, `perimeter_m float8 >= 0`, `created_at`, `updated_at`.
RLS: SELECT/UPDATE/DELETE milik sendiri atau admin; INSERT milik sendiri. Trigger: batas
plan (`You have reached the maximum of % marked areas for your plan.`), touch, storage quota.
App: `select('*')`, insert/update dengan `toRow` (`markedAreaSync.ts:44-51`: trim nama,
notes kosong→null, koordinat dibulatkan 7 desimal, `area_m2`/`perimeter_m` dihitung klien).

#### `marked_area_links`
Sama dengan `marked_location_links` dengan `area_id`.

#### `offline_maps`
Kolom (`20240203000000_create_offline_maps.sql`, `20240203000001_add_location_fields.sql`):
`id uuid PK default` (web mengirim UUID sendiri), `user_id uuid NOT NULL CASCADE`, `name text
NOT NULL`, `bounds jsonb NOT NULL` (`{north,south,east,west}`), `min_zoom int`, `max_zoom
int`, `tile_count int`, `size_est_mb float8`, `created_at`, `center_lng float8 NULL`,
`center_lat float8 NULL`, `location_name text NULL`.
RLS: INSERT/SELECT/DELETE milik sendiri; **tidak ada UPDATE**. Trigger
`check_offline_map_limits` BEFORE INSERT: Free 1 peta/1 MB, Pro 3/10 MB, Enterprise & admin
10/25 MB (`20261023000000:44-82`). Pesan: `Map size (%) exceeds the limit of % MB for % plan.`
dan `You have reached the maximum number of offline maps (%) for % plan.`
Catatan: tabel ini hanya metadata; tile disimpan di perangkat.

#### `custom_basemaps` (baca + toggle)
Kolom (`20260223000000_create_custom_basemaps.sql`): `id uuid PK`, `user_id uuid CASCADE`,
`name text`, `file_path text` (path di bucket), `file_size bigint`, `crs text NULL`
(`'EPSG:4326'`), `bounds jsonb NULL {north,south,east,west}`, `resolution jsonb NULL
{width,height}`, `is_active bool default false`, `created_at`, `updated_at`.
RLS: SELECT/UPDATE/DELETE milik sendiri; INSERT milik sendiri + `can_upload_custom_basemaps()`
(`20261024000006_security_hardening.sql:47-57`). App: `select('*').eq('user_id',uid)
.order('created_at',desc)`; `update({is_active}).eq('id',id)`.

#### `points_of_interest` (baca)
Kolom (`20261024000012_points_of_interest.sql`): `id uuid`, `legacy_id text UNIQUE NULL`,
`name text (1–120)`, `subtitle text NULL (≤120)`, `description text NULL (≤2000)`, `category
text IN ('poi','mountain','basecamp','water','river','cliff','cave')`, `lng`, `lat`,
`is_published bool default true`, `created_by uuid NULL`, `created_at`, `updated_at`.
RLS: SELECT untuk **anon** dan authenticated jika `is_published OR is_admin()`; tulis hanya
admin. App: `select('id,name,subtitle,description,category,lng,lat,is_published,updated_at')
.eq('is_published',true).order('name')` (`lib/pointsOfInterest.ts:83,123-128`).

#### `plan_storage_limits` (baca)
`plan text PK IN ('Free','Pro','Enterprise')`, `limit_mb numeric`, `updated_at`. SELECT
untuk authenticated (`20261024000004`). Biasanya tidak perlu: `my_storage_usage` sudah
memberi `limit_bytes`.

#### `sos_alerts` / `sos_alert_points` (baca)
`sos_alerts` (`20261024000015:11-30`): `id uuid PK`, `client_id uuid UNIQUE NOT NULL`, `user_id
uuid`, `status text IN ('active','resolved') default 'active'`, `message text NULL (≤500)`,
`lat/lng float8 NULL`, `accuracy float8 NULL`, `elevation float8 NULL`, `battery smallint NULL
(0–100)`, `located_at timestamptz NULL`, `started_at timestamptz NOT NULL`, `received_at
default now()`, `updated_at`, `resolved_at NULL`, `resolved_by uuid NULL`, `resolved_note text
NULL (≤500)`.
`sos_alert_points`: `id bigserial`, `alert_id uuid CASCADE`, `lat`, `lng`, `accuracy NULL`,
`elevation NULL`, `recorded_at timestamptz`.
RLS: SELECT pemilik atau admin; INSERT/UPDATE/DELETE dicabut dari klien (hanya lewat RPC).
Web tidak membaca `sos_alert_points` (hanya `point_count`); app boleh membaca untuk jejak di
peta admin.

#### `tracker_logs` / `tracker_activity_sessions` (live tracking, bersyarat)
`tracker_logs` (`20240101000001_create_tracker_logs.sql`, `20260423000001:59-61`): `id uuid`,
`user_id uuid NOT NULL`, `lat`, `lng float8 NOT NULL`, `elevation NULL`, `speed NULL`,
`battery int NULL`, `timestamp timestamptz NOT NULL`, `created_at`, `session_id uuid NULL →
tracker_activity_sessions ON DELETE SET NULL`. Dihapus otomatis setelah 7 hari (pg_cron,
`20240101000006_auto_cleanup_logs.sql`).
RLS: INSERT/SELECT milik sendiri; SELECT semua untuk `is_monitor()`. Tidak ada UPDATE/DELETE.
`tracker_activity_sessions` (`20260423000001`): `id uuid PK`, `user_id`, `started_at NOT NULL`,
`ended_at NULL`, `distance_m float8 default 0`, `point_count int default 0`, `created_at`.
RLS: INSERT/SELECT/UPDATE milik sendiri; SELECT semua untuk `is_monitor()`.
Web: `upsert([{id,user_id,started_at,distance_m?,point_count?,ended_at?}], onConflict:'id')`
(`TrackerService.ts:279-290`), `insert({user_id,session_id,lat,lng,elevation,speed,battery,timestamp})`
(`TrackerService.ts:415-438`).

#### Tabel yang **tidak boleh** disentuh app
`account_requests` (RLS tanpa policy + `REVOKE ALL`, hanya `/api/account-requests`),
`login_events` (hanya lewat RPC `record_login`/`record_logout`), `reviews` (hanya RPC).

### 2.3 RPC yang dipakai app

Format: `nama(arg tipe [default])` → bentuk hasil · grant · gerbang · error utama · file.

**Akun**
- `record_login(p_user_agent text)` → `void` · authenticated · diabaikan jika sama dalam 1 menit; simpan 200 terakhir · `20261024000008_activity_log.sql`. App kirim mis. `"Landscape360/1.0.0 (Android 15; Pixel 8)"` (≤400 char).
- `record_logout(p_user_agent text)` → `void` · panggil **sebelum** `signOut()`, timeout 2 s (`lib/loginHistory.ts:17-24`).
- `update_my_contact(p_organization text, p_phone text)` → `void` · string kosong = hapus · error `Organization must be at most 120 characters`, `Phone / WhatsApp number must have 8 to 15 digits`, `Not signed in` · `20261024000009_profile_contact.sql`. Web mengirim `''` untuk null (`profileContact.ts:29-35`).
- `my_storage_usage()` → `[{tracks_bytes bigint, locations_bytes bigint, surveys_bytes bigint, basemaps_bytes bigint, used_bytes bigint, limit_bytes bigint|null}]` (`locations_bytes` sudah termasuk marked areas, `20261026000019` §4) · `20261024000004`.

**Track Recorder** (`20261024000001`, `20261024000004`, `20261024000017_share_fixes.sql`)
- `share_recorded_track(p_track_id uuid, p_email text)` → `[{shared_with uuid, email text, created_at timestamptz}]` · owner + `can_use_track_recorder()` · error `Track not found or not yours`, `Your plan does not allow sharing tracks`, `No Landscape360 account found for <email>`, `You cannot share a track with yourself`.
- `list_recorded_track_shares(p_track_id uuid)` → `[{shared_with, email, created_at}]` (hanya milik saya).
- `list_tracks_shared_with_me()` → `[{id, user_id, name, mode, status, started_at, ended_at, elapsed_ms, distance_m, moving_time_ms, elevation_gain_m, elevation_loss_m, max_alt_m, min_alt_m, point_count int, updated_at, owner_email text, shared_at}]` (tanpa `points`; ambil lewat `select('points').eq('id',…)` yang diizinkan RLS share).
- `rename_recorded_track(p_track_id uuid, p_name text)` → `void` · admin/Pro/Enterprise · error `Renaming tracks needs a Pro or Enterprise plan`, `Track not found or not yours`.

**Marked Locations** (`20261024000003`, `20261024000017`, `20261026000018`)
- `share_marked_locations(p_location_ids uuid[], p_recipient text)` → `[{shared_with uuid, name text|null, email_masked text|null, shared_count int}]` · `can_share_marked_locations()`, semua id milik saya, 1–500 id · `p_recipient` = UUID akun (dari saran), email, atau display name persis · error: `Your plan does not allow sharing locations`, `Select at least one location to share`, `You can share at most 500 locations at once`, `You can only share your own locations`, `Enter the recipient's email or name`, `No Landscape360 account found for "<x>"`, `Several accounts use the name "<x>". Pick one from the list or use their email.`, `You cannot share with yourself`.
- `marked_location_share_suggestions(p_query text default '')` → `[{user_id uuid, name text|null, email_masked text|null, recent bool}]` · maks 6 · query < 2 huruf = penerima terakhir · kosong jika plan tidak boleh share.
- `list_marked_location_shares(p_location_id uuid)` → `[{shared_with, name, email_masked, created_at}]`.
- `list_marked_locations_shared_with_me()` → `[{id, user_id, name, category, lng, lat, elevation_m, description, address, contact, tags text[], created_at, updated_at, owner_name, owner_email_masked, shared_at}]`.
- `create_marked_location_link(p_location_id uuid)` → `text` token 32-hex (link aktif lama dipakai ulang) · error plan / bukan milik.
- `get_marked_location_link(p_location_id uuid)` → `text|null`.
- `revoke_marked_location_link(p_location_id uuid)` → `void`.
- `open_marked_location_link(p_token text)` → `[{name, category, lng, lat, elevation_m, description, address, contact, tags, updated_at, owner_name}]` atau `[]` · **anon + authenticated**.

**Marked Areas** (`20261026000019`)
- `create_marked_area_link(p_area_id uuid)` → `text` · error `Your plan does not allow sharing areas`, `You can only share your own areas`.
- `get_marked_area_link(p_area_id uuid)` → `text|null`; `revoke_marked_area_link(p_area_id uuid)` → `void`.
- `open_marked_area_link(p_token text)` → `[{name, color, notes, ring jsonb, area_m2, perimeter_m, updated_at, owner_name}]` atau `[]` · **anon + authenticated**.

**S.O.S** (`20261024000015`, `20261024000016_sos_delete.sql`)
- `sos_report(p_client_id uuid, p_started_at timestamptz, p_status text default 'active', p_message text default null, p_lat float8 null, p_lng float8 null, p_accuracy float8 null, p_elevation float8 null, p_battery smallint null, p_located_at timestamptz null)` → `uuid` (id alert) · `can_use_sos()` · idempoten per `p_client_id`; field null tidak menimpa; status `resolved` permanen; titik jejak baru hanya jika lat/lng berubah · error `S.O.S is not enabled for this account`, `Invalid status`, `Not your S.O.S`. Pemanggilan web: `lib/sosAlerts.ts:38-61` (pesan kosong → null).
- `can_use_sos()` → `bool` (opsional, cek server).
- `admin_sos_alerts(p_only_active bool default true, p_limit int default 50)` → `[{id, user_id, email, name, phone, organization, status, message, lat, lng, accuracy, elevation, battery smallint, located_at, started_at, received_at, updated_at, resolved_at, resolved_note, point_count bigint}]` · admin, limit 1–200, urut aktif dulu lalu `started_at desc` · error `Not allowed`. Web memakai `p_limit: 100`.
- `admin_resolve_sos(p_id uuid, p_note text default null)` → `void` · admin.
- `admin_delete_sos(p_id uuid)` → `void` · admin · error `Resolve the S.O.S before deleting it`.

**Live tracking (bersyarat)**
- `get_tracker_activity_sessions(p_user_id uuid default null, p_limit int default 50, p_offset int default 0)` → `[{session_id, user_id, started_at, ended_at, distance_m, point_count bigint, last_point_at}]` · non-monitor dipaksa data sendiri · `20260423000001`.
- `get_tracker_sessions(...)` (lama, per tanggal) tidak dipakai web lagi.

**Opsional (nanti)**: `list_reviews(p_rating smallint, p_limit int, p_offset int)`,
`review_summary()`, `my_review()`, `submit_review(p_rating smallint, p_comment text)`,
`delete_my_review()` (`20261024000007_reviews.sql`, `20261024000011_review_organization.sql`).

Error kuota storage (semua tabel di atas): `Storage limit reached: X MB of Y MB used and this
needs Z MB more. Delete some data or contact the admin for more space.` dengan
`ERRCODE P0001`, `HINT 'storage_quota'` (`20261024000004:assert_storage_quota`).

### 2.4 Storage bucket

| Bucket | Publik | Batas | Policy `storage.objects` | Dipakai app |
|---|---|---|---|---|
| `custom-basemaps` | tidak | `file_size_limit` 10 MB, `allowed_mime_types ['image/png']` (`20261024000006:13-17`) | INSERT: folder pertama = `auth.uid()` + `can_upload_custom_basemaps()`; SELECT/DELETE: `owner = auth.uid()` (`20260223000000:52-58`, `20261024000006:36-44`) | Hanya `createSignedUrl(file_path, 3600)` untuk basemap aktif, tampilkan sebagai image source dengan `bounds` (koordinat sudut dari `{north,south,east,west}`) |

Path yang ditulis web: `<user_id>/<epoch_ms>_<nama_disanitasi>.png`
(`useCustomBasemapStore.ts:499`). Tidak ada bucket lain.

### 2.5 Endpoint `/api` (Vercel Functions)

Semua respons JSON. Error selalu `{"error": "<pesan>"}` dengan status di bawah; 500 tak
terduga = `{"error":"Internal server error"}`. Panggilan admin memerlukan
`Authorization: Bearer <access_token>`; perilaku 401 → `refreshSession()` sekali → ulangi →
jika masih 401, tampilkan `Your session has ended. Please sign out and sign in again.`
(`src/lib/authFetch.ts`).

#### `POST /api/account-requests` (publik, tanpa token) — **v1**
Header: `Content-Type: application/json`. Body:
```json
{ "email": "a@b.co", "fullName": "…", "organization": "…|null", "phone": "…|null",
  "message": "…", "requestedPlan": "Free", "website": "" }
```
- `email` wajib, ≤254, pola `^[^\s@]+@[^\s@]+\.[^\s@]+$`, di-lowercase.
- `fullName` wajib ≤120; `organization` opsional ≤120; `phone` opsional ≤20, pola
  `^\+?(?:[\s-]*\d){8,15}$`; `message` **wajib** ≤1000; `requestedPlan` hanya `Free`.
- `website` = honeypot: isi apa pun → langsung `201 {ok:true}` tanpa menyimpan. App kirim `""`
  atau hilangkan.
Respons: `201 {"ok": true}` (juga jika email sudah terdaftar / request ganda, sengaja sama).
Error: `400` (validasi, `Invalid JSON body`), `429 Too many requests right now. Please try
again later.` (lebih dari 30 request/jam **global**), `500`. (`api/account-requests.ts:113-168`)

#### Endpoint admin (web saja, dicatat untuk kelengkapan)
`GET/POST/PATCH/PUT/DELETE /api/admin-users`, `GET/PATCH/DELETE /api/account-requests`:
`401 Missing access token` / `401 Invalid or expired session` / `403 Not allowed` (bukan
`is_admin`) (`api/admin-users.ts:58-74`, `api/account-requests.ts:58-74`). App v1 **tidak**
memanggilnya.

#### Endpoint baru yang dibutuhkan (Fase 6b/8, belum ada)
- `DELETE /api/account` (nama usulan): hapus akun pemanggil (`auth.admin.deleteUser(uid)`),
  tolak jika `is_admin` (admin tunggal), `401/403/500` mengikuti pola di atas; FK sudah
  cascade (`20261024000010`). Hapus juga file basemap di storage (`<uid>/…`) karena objek
  storage tidak ikut cascade.
- Push S.O.S: tabel token perangkat + Edge Function/Database Webhook (Q3).

### 2.6 Realtime

Live tracking memakai channel Supabase Realtime **publik** `tracking-room`
(`TrackerService.ts:615-619`): `broadcast.self=false`, presence key = `user.id`. Event:
- `location-update` payload `TrackerPacket` (§3.4) dikirim tiap ≥3 s saat broadcast aktif.
- `heartbeat-request` payload `{}` dikirim monitor saat join; broadcaster membalas dengan
  `location-update` terakhir.
- Presence `track({user_id, role, online_at})`.
Tidak ada policy `realtime.messages` di migration (lihat S1). S.O.S admin tidak memakai
realtime (polling 30 s).

### 2.7 Matriks gerbang plan / role / admin / S.O.S

| Kemampuan | Cek di klien web | Penegakan server | Celah |
|---|---|---|---|
| Simpan survei (jumlah 2/4/10) | `useSurveyStore.ts:343-361` | hanya kuota storage | jumlah tidak ditegakkan |
| Offline map 1/3/10 & 1/10/25 MB | `RegionDrawingOverlay.tsx:148-165` | trigger `check_offline_map_limits` (baris metadata) | unduhan tile tidak ditegakkan server |
| Rekam track | `canRecordTracks` (`useTrackRecorderStore.ts:24-28`): admin/Enterprise | RLS insert/update `can_use_track_recorder()` | — |
| Rename track cloud | `canRenameCloudTracks`: admin/Pro/Ent | RPC `rename_recorded_track` | — |
| Share track | UI Enterprise/admin | RPC + RLS | — |
| GPS broadcast | `ControlPanel.tsx:213-216,835`: bukan Free; flag `VITE_ENABLE_GPS_TRACKER` | **tidak ada** | S1, S2 |
| Record Activity | `ControlPanel.tsx:251-254`: `pengguna360` + Pro | **tidak ada** (RLS hanya `user_id`) | S2 |
| Monitor live | `monitor360` + Enterprise (`TrackerService.ts:624`) | realtime **tidak ada**; tabel `is_monitor()` | S1 |
| Riwayat tracker | `TrackerHistoryViewer.tsx:82-86` | RPC/RLS milik sendiri atau `is_monitor()` | — |
| Marked locations (10/100/1000, admin ∞) | `getMarkedLocationPolicy` | trigger | — |
| Share lokasi / link lokasi / link area | Pro/Ent/admin | `can_share_marked_locations()` di RPC | — |
| Marked areas (5/10/20, admin ∞) | `getMarkedAreaPolicy` | trigger | — |
| Kuota storage (10/100/1024 MB, override, admin ∞) | tampilan | trigger `assert_storage_quota` | S9 (basemap) |
| Upload basemap | 5 MB total (`useCustomBasemapStore.ts:81`) | `can_upload_custom_basemaps()` + bucket PNG ≤10 MB | S9 |
| S.O.S | `canUseSos || isAdmin` (`SosButton.tsx:15`) | `can_use_sos()` di `sos_report` | — |
| Admin S.O.S, POI, admin marked locations | `isAdmin` | `is_admin()` di RPC/RLS | — |
| Ubah plan/role/admin/can_use_sos/storage | — | tidak ada policy UPDATE `profiles`; hanya service role | aman (S7) |

---

## 3. Model data Dart

Konvensi: paket `freezed` + `json_serializable`, `@JsonKey(name: …)` sesuai kolom/JSON di
bawah, `@JsonSerializable(includeIfNull: false)` untuk JSON yang disimpan di `surveys.data`
(web menghilangkan field `undefined`). Waktu dari Postgres → `DateTime` (UTC). Angka Postgres
`float8`/`numeric` → `double` (pakai `(json as num).toDouble()`; `numeric` bisa datang sebagai
string pada beberapa klien — gunakan konverter `num.parse` toleran).

### 3.1 Survei (`surveys.data`)

Bentuk persis yang ditulis web (`useSurveyStore.ts:7-36,368-373`): `data` = **array
`SurveyGroup`**.

```dart
enum PointCorner { smooth, sharp }          // JSON: "smooth" | "sharp"
enum AngleStep { free, deg15, deg45, deg90 } // lokal saja (0/15/45/90), tidak disimpan di cloud

@freezed class SurveyHandle {               // meter ke timur/utara dari titik
  const factory SurveyHandle({
    required double east,                    // "east"
    required double north,                   // "north"
  }) = _SurveyHandle;
}

@freezed class SurveyPoint {
  const factory SurveyPoint({
    required String id,                      // "id" (UUID v4, dibuat klien)
    required double lng,                     // "lng"
    required double lat,                     // "lat"
    required double elevation,               // "elevation" meter (selalu ada)
    String? name,                            // "name" (opsional)
    PointCorner? corner,                     // "corner"; null/absen = smooth (data lama)
    SurveyHandle? handle,                    // "handle"; absen = tangen otomatis
  }) = _SurveyPoint;
}

@freezed class SurveyGroup {                 // satu "sheet" / jalur
  const factory SurveyGroup({
    required String id,                      // "id"
    required String name,                    // "name" (default "Survey N")
    required List<SurveyPoint> points,       // "points"
    required String color,                   // "color" (#RRGGBB dari COLORS)
  }) = _SurveyGroup;
}

@freezed class Survey {                      // baris tabel surveys
  const factory Survey({
    required String id,                      // "id"
    @JsonKey(name: 'user_id') required String userId,
    String? name,                            // "name"
    @Default([]) List<SurveyGroup> data,     // "data"
    @JsonKey(name: 'created_at') DateTime? createdAt,
    @JsonKey(name: 'updated_at') DateTime? updatedAt,
  }) = _Survey;
}

@freezed class SavedSurveySummary {          // list: select id,name,updated_at
  const factory SavedSurveySummary({ required String id, required String name,
    @JsonKey(name: 'updated_at') required DateTime updatedAt }) = _SavedSurveySummary;
}
```
Aturan: `setPointCorner` menghapus `handle`; `setPointHandle` memaksa `corner='smooth'`;
`sharpenLast` membuat titik terakhir `sharp` tanpa handle (`useSurveyStore.ts:518-598`).
Warna sheet: `['#FFD700','#00FF7F','#00BFFF','#FF69B4','#FFA500']` berputar. Nama survei
saat simpan = argumen atau nama sheet pertama atau `'Untitled Survey'`. **Jangan** menulis
`"corner": null` / `"handle": null` (pakai `includeIfNull: false`).

### 3.2 Track Recorder

```dart
enum TrackMode { online, offline }
enum TrackStatus { recording, paused, completed }
enum TrackSyncStatus { local, pending, synced, error, remote } // lokal saja

@freezed class TrackPoint {                  // lokal (drift); cloud = CompactPoint
  const factory TrackPoint({
    required double lat, required double lng,
    double? alt,                             // m, null jika tidak ada
    required double accuracy,                // m
    double? speed,                           // m/s, TIDAK diunggah
    required int timestamp,                  // epoch ms
    required int segment,                    // naik tiap resume
  }) = _TrackPoint;
}
// Cloud: List<dynamic> [lng, lat, alt|null, timestamp_ms, accuracy, segment]
// (trackRecorderSync.ts:10,34-38). fromCompact => speed = null.

@freezed class RecordedTrack {
  const factory RecordedTrack({
    required String id,                      // "id" UUID dari klien
    @JsonKey(name: 'user_id') required String userId,
    required String name,                    // 1–120
    required TrackMode mode,
    required TrackStatus status,
    @JsonKey(name: 'started_at') required DateTime startedAt,
    @JsonKey(name: 'ended_at') DateTime? endedAt,
    @JsonKey(name: 'elapsed_ms') required int elapsedMs,       // dibulatkan
    @JsonKey(name: 'distance_m') required double distanceM,
    @JsonKey(name: 'moving_time_ms') required int movingTimeMs, // dibulatkan
    @JsonKey(name: 'elevation_gain_m') required double elevationGainM,
    @JsonKey(name: 'elevation_loss_m') required double elevationLossM,
    @JsonKey(name: 'max_alt_m') double? maxAltM,
    @JsonKey(name: 'min_alt_m') double? minAltM,
    @JsonKey(name: 'point_count') required int pointCount,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
    // lokal saja (includeFromJson/ToJson: false):
    int? lastResumedAt, @Default(TrackSyncStatus.local) TrackSyncStatus syncStatus,
    String? syncError, DateTime? syncedAt,
  }) = _RecordedTrack;
}

@freezed class SharedTrack {                 // list_tracks_shared_with_me
  // semua field RecordedTrack (tanpa points) +
  //   @JsonKey(name: 'owner_email') String? ownerEmail,
  //   @JsonKey(name: 'shared_at') required DateTime sharedAt,
}

@freezed class TrackShare {                  // share_recorded_track / list_recorded_track_shares
  const factory TrackShare({
    @JsonKey(name: 'shared_with') required String userId,
    required String email,
    @JsonKey(name: 'created_at') required DateTime sharedAt,
  }) = _TrackShare;
}
```
Konstanta `TRACK_RECORDER_CONFIG` (`types/trackRecorder.ts:67-82`): `MAX_ACCURACY_M 50`,
`MIN_DISTANCE_M 5`, `MAX_SPEED_MS 70`, `ELEVATION_THRESHOLD_M 3`, `MOVING_SPEED_MS 0.3`,
`MAX_MOVING_GAP_MS 120000`, `AUTO_SYNC_INTERVAL_MS 60000`.

### 3.3 Marked location & area, link

```dart
enum MarkedLocationCategory { poi, camp, summit, water, shelter, viewpoint,
  trailhead, hazard, cave, parking }        // nilai JSON = nama enum

@freezed class MarkedLocation {
  const factory MarkedLocation({
    required String id,
    @JsonKey(name: 'user_id') required String userId,
    required String name,
    required MarkedLocationCategory category,
    required double lng, required double lat,
    @JsonKey(name: 'elevation_m') double? elevationM,
    String? description, String? address, String? contact,
    @Default([]) List<String> tags,          // null dari server => []
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _MarkedLocation;
}
// Input insert/update (toRow, markedLocationSync.ts:49-59): name.trim(), category, lng, lat,
// elevation_m, description/address/contact trim()||null, tags. Tanpa id/user_id.

@freezed class SharedMarkedLocation {        // list_marked_locations_shared_with_me
  // field MarkedLocation +
  //   @JsonKey(name: 'owner_name') String? ownerName,
  //   @JsonKey(name: 'owner_email_masked') String? ownerEmailMasked,
  //   @JsonKey(name: 'shared_at') required DateTime sharedAt,
}

@freezed class MarkedLocationShare {         // list_marked_location_shares
  @JsonKey(name: 'shared_with') String userId; String? name;
  @JsonKey(name: 'email_masked') String? emailMasked;
  @JsonKey(name: 'created_at') DateTime sharedAt;
}

@freezed class ShareSuggestion {             // marked_location_share_suggestions
  @JsonKey(name: 'user_id') String userId; String? name;
  @JsonKey(name: 'email_masked') String? emailMasked; bool recent;
}

@freezed class ShareResult {                 // share_marked_locations
  @JsonKey(name: 'shared_with') String userId; String? name;
  @JsonKey(name: 'email_masked') String? emailMasked;
  @JsonKey(name: 'shared_count') int sharedCount;
}

@freezed class LinkedLocation {              // open_marked_location_link (tanpa id/user_id)
  String name; MarkedLocationCategory category; double lng; double lat;
  @JsonKey(name: 'elevation_m') double? elevationM;
  String? description; String? address; String? contact; @Default([]) List<String> tags;
  @JsonKey(name: 'updated_at') DateTime updatedAt;
  @JsonKey(name: 'owner_name') String? ownerName;
}

typedef LngLat = (double lng, double lat);   // JSON: [lng, lat]

@freezed class MarkedArea {
  const factory MarkedArea({
    required String id,
    @JsonKey(name: 'user_id') required String userId,
    required String name,                    // 1–120
    required String color,                   // "#rrggbb"
    String? notes,                           // ≤2000
    @LngLatListConverter() required List<LngLat> ring, // 3–500, TIDAK ditutup
    @JsonKey(name: 'area_m2') required double areaM2,
    @JsonKey(name: 'perimeter_m') required double perimeterM,
    @JsonKey(name: 'created_at') required DateTime createdAt,
    @JsonKey(name: 'updated_at') required DateTime updatedAt,
  }) = _MarkedArea;
}
// Input (markedAreaSync.ts:44-51): name.trim(), color, notes.trim()||null,
// ring dibulatkan 7 desimal, area_m2 = ringArea(input), perimeter_m = ringPerimeter(input).
// Warna pilihan: AREA_COLORS (utils/markedAreas.ts:21).

@freezed class LinkedArea {                  // open_marked_area_link
  String name; String color; String? notes; List<LngLat> ring;
  @JsonKey(name: 'area_m2') double areaM2; @JsonKey(name: 'perimeter_m') double perimeterM;
  @JsonKey(name: 'updated_at') DateTime updatedAt; @JsonKey(name: 'owner_name') String? ownerName;
}

@freezed class ShareLinkRow {                // marked_location_links / marked_area_links (SELECT milik sendiri)
  String token;                              // ^[0-9a-f]{32}$
  @JsonKey(name: 'location_id') String? locationId;   // salah satu terisi
  @JsonKey(name: 'area_id') String? areaId;
  @JsonKey(name: 'owner_id') String ownerId;
  @JsonKey(name: 'created_at') DateTime createdAt;
  @JsonKey(name: 'revoked_at') DateTime? revokedAt;
}

sealed class IncomingLink {                  // dari app_links (lib/shareLocation.ts)
  // PointLink(lat, lng)   ?at=lat,lng   (validasi -90..90 / -180..180)
  // PlaceLink(token)      ?place=<32 hex>
  // AreaLink(token)       ?area=<32 hex>
}
```

### 3.4 S.O.S

```dart
enum SosStatus { active, resolved }

@freezed class SosFix {                      // lib/sos.ts:20-26
  double lat; double lng; double? accuracy; double? elevation; int time; // epoch ms
}

@freezed class EmergencyContact { String name; String phone; } // lokal per akun, maks 5
// kunci web: localStorage 'l360-sos-contacts-<userId>'

@freezed class SosReport {                   // outbox lokal (drift), 1 baris per clientId
  required String clientId;                  // UUID v4 per S.O.S
  required DateTime startedAt;
  required SosStatus status;
  required String message;                   // '' => p_message null
  SosFix? fix;
  int? battery;                              // 0–100
}
// Peta ke RPC sos_report: p_client_id, p_started_at (ISO), p_status, p_message,
// p_lat, p_lng, p_accuracy, p_elevation, p_battery, p_located_at (ISO dari fix.time).

@freezed class SosAlert {                    // admin_sos_alerts
  required String id;
  @JsonKey(name: 'user_id') required String userId;
  @Default('') String email;
  String? name; String? phone; String? organization;
  required SosStatus status;                 // selain 'resolved' => active
  String? message; double? lat; double? lng; double? accuracy; double? elevation;
  int? battery;
  @JsonKey(name: 'located_at') DateTime? locatedAt;
  @JsonKey(name: 'started_at') required DateTime startedAt;
  @JsonKey(name: 'received_at') required DateTime receivedAt;
  @JsonKey(name: 'updated_at') required DateTime updatedAt;
  @JsonKey(name: 'resolved_at') DateTime? resolvedAt;
  @JsonKey(name: 'resolved_note') String? resolvedNote;
  @JsonKey(name: 'point_count') @Default(0) int pointCount;
}

@freezed class SosAlertPoint {               // sos_alert_points (SELECT)
  int id; @JsonKey(name: 'alert_id') String alertId; double lat; double lng;
  double? accuracy; double? elevation; @JsonKey(name: 'recorded_at') DateTime recordedAt;
}
```

### 3.5 Profil, plan, role, storage

```dart
enum Plan { Free, Pro, Enterprise }          // JSON persis 'Free'|'Pro'|'Enterprise'
enum Role { pengguna360, monitor360 }        // JSON persis

@freezed class Profile {
  const factory Profile({
    required String id,
    String? email,
    @JsonKey(name: 'status_subscribe') @Default(Plan.Free) Plan plan,      // nilai tak dikenal => Free
    @JsonKey(name: 'status_user') @Default(Role.pengguna360) Role role,
    @JsonKey(name: 'is_admin') @Default(false) bool isAdmin,
    @JsonKey(name: 'can_use_sos') @Default(false) bool canUseSos,
    String? organization, String? phone,
    @JsonKey(name: 'storage_limit_mb') double? storageLimitMb,
    @JsonKey(name: 'created_at') DateTime? createdAt,
    @JsonKey(name: 'updated_at') DateTime? updatedAt,
  }) = _Profile;
}
// Derivasi (sama dengan web): effectivePlan = isAdmin ? Enterprise : plan;
// effectiveRole = isAdmin ? monitor360 : role; effectiveCanUseSos = isAdmin || canUseSos.
// displayName = userMetadata['display_name'] ?? ['full_name'] ?? ['name'] ?? ''.
// Simpan Profile terakhir di penyimpanan lokal; saat offline jangan menurunkan canUseSos.

@freezed class MyStorageUsage {              // my_storage_usage()[0]
  @JsonKey(name: 'tracks_bytes') int tracksBytes;
  @JsonKey(name: 'locations_bytes') int locationsBytes;  // termasuk marked areas
  @JsonKey(name: 'surveys_bytes') int surveysBytes;
  @JsonKey(name: 'basemaps_bytes') int basemapsBytes;
  @JsonKey(name: 'used_bytes') int usedBytes;
  @JsonKey(name: 'limit_bytes') int? limitBytes;         // null = tanpa batas
}

@freezed class AccountRequestInput {         // POST /api/account-requests (camelCase!)
  required String email; required String fullName;
  String? organization; String? phone; required String message;
  @Default('Free') String requestedPlan; @Default('') String website;
}
```

### 3.6 Offline map, basemap kustom, POI, live tracking

```dart
@freezed class GeoBounds { double north; double south; double east; double west; }

@freezed class OfflineMap {                  // offline_maps
  required String id;                        // UUID dari klien = id TileRegion Mapbox
  @JsonKey(name: 'user_id') required String userId;
  required String name;
  required GeoBounds bounds;
  @JsonKey(name: 'min_zoom') required int minZoom;
  @JsonKey(name: 'max_zoom') required int maxZoom;
  @JsonKey(name: 'tile_count') required int tileCount;
  @JsonKey(name: 'size_est_mb') required double sizeEstMb;
  @JsonKey(name: 'created_at') DateTime? createdAt;
  @JsonKey(name: 'center_lng') double? centerLng;
  @JsonKey(name: 'center_lat') double? centerLat;
  @JsonKey(name: 'location_name') String? locationName;
  // lokal saja: status (downloading|completed|error), progress 0..100, bytes nyata
}

@freezed class CustomBasemap {               // custom_basemaps
  required String id;
  @JsonKey(name: 'user_id') required String userId;
  required String name;
  @JsonKey(name: 'file_path') required String filePath;
  @JsonKey(name: 'file_size') required int fileSize;
  String? crs;                               // 'EPSG:4326'
  GeoBounds? bounds;
  BasemapResolution? resolution;             // {width:int, height:int}
  @JsonKey(name: 'is_active') @Default(false) bool isActive;
  @JsonKey(name: 'created_at') DateTime? createdAt;
  @JsonKey(name: 'updated_at') DateTime? updatedAt;
  // lokal saja: String? signedUrl (berlaku 3600 s), double opacity
}

enum PoiCategory { poi, mountain, basecamp, water, river, cliff, cave }

@freezed class PointOfInterest {             // points_of_interest
  required String id; required String name;
  String? subtitle;                          // mis. "2.958 mdpl", "Permanent"
  String? description; required PoiCategory category;
  required double lng; required double lat;
  @JsonKey(name: 'is_published') @Default(true) bool isPublished;
  @JsonKey(name: 'updated_at') DateTime? updatedAt;
}

@freezed class TrackerPacket {               // broadcast 'location-update' (types/tracker.ts)
  @JsonKey(name: 'user_id') required String userId; // web: local-part email UPPERCASE (lihat S1)
  required double lat; required double lng;
  double? alt; double? speed;
  required int battery;                      // web selalu 100
  required String timestamp;                 // ISO
  required String status;                    // 'active'|'idle'|'sos'|'offline'
}

@freezed class TrackerLog {                  // tracker_logs insert
  @JsonKey(name: 'user_id') String userId; @JsonKey(name: 'session_id') String? sessionId;
  double lat; double lng; double? elevation; double? speed; int? battery;
  DateTime timestamp;
}

@freezed class TrackerActivitySession {      // tracker_activity_sessions / RPC
  required String id;                        // RPC: "session_id"
  @JsonKey(name: 'user_id') required String userId;
  @JsonKey(name: 'started_at') required DateTime startedAt;
  @JsonKey(name: 'ended_at') DateTime? endedAt;
  @JsonKey(name: 'distance_m') @Default(0) double distanceM;
  @JsonKey(name: 'point_count') @Default(0) int pointCount;
  @JsonKey(name: 'last_point_at') DateTime? lastPointAt; // RPC saja
}
```

---

## 4. Logika yang di-port ke Dart

Setiap fungsi wajib punya test Dart dengan kasus yang sama dengan test web (hasil identik,
toleransi angka sama dengan `toBeCloseTo` di web).

| # | Fungsi | Sumber | Test web acuan | Catatan port |
|---|---|---|---|---|
| 1 | `geodesicInverse` (Vincenty WGS84 + fallback antipodal), `getAzimuthData` (azimuth maju/balik, jarak, slope %/°), `formatDegrees`, `formatDistance`, `toDMS`, `toUTM` | `src/utils/surveyUtils.ts:14-250` | `src/utils/surveyUtils.test.ts` | Konstanta WGS84 a=6378137, f=1/298.257223563 |
| 2 | `snapToAngle` | `surveyUtils.ts:261-276` | `surveyUtils.test.ts` | Memakai turf **bola** (`bearing`, `distance`, `destination`, R = 6371008.8 m): port rumus turf, bukan Vincenty |
| 3 | `handleFromDrag`, `handleEnds`, `buildSurveyLine` (Catmull-Rom/Bezier, 32 sampel), `segmentMidpoints` | `surveyUtils.ts:278-367` | `surveyUtils.test.ts` | Proyeksi lokal `METERS_PER_DEGREE = π/180 × 6378137` |
| 4 | Operasi grup/titik survei, batas 2/4/10, `sharpenLast` | `src/store/useSurveyStore.ts` | `src/store/useSurveyStore.test.ts` | |
| 5 | `haversineDistance`, `shouldRejectPoint`, `accumulatePoint(s)`, `getElapsedMs`, `splitSegments`, `getBounds`, `buildGpx`, `formatDistance`, `formatDuration` | `src/utils/trackRecorderGeo.ts` | `src/utils/trackRecorderGeo.test.ts` | **Haversine R = 6 371 000 m** (bukan Vincenty) agar statistik sama dengan web |
| 6 | `canRecordTracks`, `canRenameCloudTracks`, mesin status rekam (start/pause/resume/stop/recover) | `src/store/useTrackRecorderStore.ts` | `src/store/useTrackRecorderStore.test.ts` | |
| 7 | `toCompact`/`fromCompact`/`toRow`/`fromRow` track | `src/services/trackRecorderSync.ts:34-79` | (diuji lewat store test) | Tambah test Dart sendiri |
| 8 | `getMarkedLocationPolicy`, `parseTags`, `isValidCoordinate`, `formatLatLng`, `directionsUrl`, `toGpx`, `CATEGORY_META` | `src/utils/markedLocations.ts` | `src/utils/markedLocations.test.ts`, `src/store/useMarkedLocationStore.test.ts` | |
| 9 | `getMarkedAreaPolicy`, `ringArea`, `ringPerimeter`, `formatArea`, `formatLength`, `ringBounds`, `ringCenter`, `focusMask`, `areaInputError` | `src/utils/markedAreas.ts` | `src/utils/markedAreas.test.ts` | `ringArea` = algoritma `@turf/area` 7.3.3 (bola R = 6371008.8 m); `ringPerimeter` = Vincenty |
| 10 | `toRow` area (pembulatan 7 desimal) | `src/services/markedAreaSync.ts:44-51` | — | Test Dart baru |
| 11 | `sharedLocationUrl`, `parseSharedPoint`, `buildShareLocationText`, `placeLinkUrl`, `parsePlaceToken`, `buildPlaceShareText`, `areaLinkUrl`, `parseAreaToken`, `buildAreaShareText`, `whatsappShareUrl` | `src/lib/shareLocation.ts` | `src/lib/shareLocation.test.ts` | Format tanggal `dd/MM HH:mm` waktu lokal |
| 12 | `buildSosMessage`, `smsUrl` (iOS `&`, lainnya `?`), `emergencyContactError`, `SOS_LIGHT_PATTERN`, `EMERGENCY_NUMBERS`, `MAX_EMERGENCY_CONTACTS` | `src/lib/sos.ts` | `src/lib/sos.test.ts` | |
| 13 | Outbox S.O.S (`queueSosReport`, `flushSosOutbox` — hapus hanya jika laporan tidak berubah saat dikirim), pemetaan RPC, `listSosAlerts` | `src/lib/sosAlerts.ts` | `src/lib/sosAlerts.test.ts`, `src/components/SosScreen.report.test.tsx` | Outbox di drift, juga dikirim dari background |
| 14 | `readCompass`, `createCompassQualityTracker` (30°, lompatan 40° dalam 100 ms ×3 dalam 3 s, tahan 4 s) | `src/lib/deviceHeading.ts:21-80` | `src/lib/deviceHeading.test.ts` | Di native, sumber heading berbeda (iOS `CLHeading.headingAccuracy`, Android sensor accuracy); logika lompatan tetap |
| 15 | `authFetch` (401 → refresh sekali → ulang) | `src/lib/authFetch.ts` | `src/lib/authFetch.test.ts` | |
| 16 | `passwordChangeError`, `changeMyPassword` | `src/lib/accountPassword.ts` | `src/lib/accountPassword.test.ts` | |
| 17 | `accountDisplayName`, `isValidPhone`, `whatsappUrl` (0… → 62…) | `src/lib/profileContact.ts` | `src/lib/profileContact.test.ts` | |
| 18 | `formatBytes`, `formatMb`, `usagePercent` | `src/lib/storageUsage.ts` | `src/lib/storageUsage.test.ts` | |
| 19 | `toMapLocation`, `guessCategory`, `poiInputError`, `BUNDLED_POIS` | `src/lib/pointsOfInterest.ts` | `src/lib/pointsOfInterest.test.ts` | Hanya fallback & tampilan |
| 20 | `recordLogin`/`recordLogout` (non-blocking, timeout 2 s) | `src/lib/loginHistory.ts` | `src/lib/loginHistory.test.ts` | `describeUserAgent`/`timeAgo` tidak perlu (admin) |
| 21 | `getTilesInBounds` (estimasi jumlah tile) | `src/utils/tileUtils.ts` | `src/components/RegionDrawingOverlay.test.tsx` (tidak langsung) | Estimasi ukuran Mapbox TileStore berbeda; tetap kirim `size_est_mb` |
| 22 | `decodeTerrainRgb`, `tilePixelFor` | `src/utils/elevationUtils.ts` | `src/utils/elevationUtils.test.ts` | Opsional (SDK punya `queryTerrainElevation`) |
| 23 | Grid DMS & kontur | `GridDMSLayer.tsx`, `ContourLayer.tsx`, `utils/TurfContourProvider.ts` | — | Tanpa test web; buat test Dart untuk interval grid |
| 24 | Mode tracker (aktif/idle/offline, 60 s) | `src/services/TrackerService.ts`, `src/store/useTrackerStore.ts` | `src/services/TrackerMode.test.ts`, `TrackerService.test.ts`, `useTrackerStore.test.ts` | Hanya jika live tracking masuk v1 |

Tidak perlu di-port (admin/web): `src/lib/adminEmail.ts` (`planBroadcast`, test
`adminEmail.test.ts`), `src/lib/adminUsers.ts`, `src/lib/accountRequests.ts:generatePassword`,
`describeUserAgent`, `timeAgo`.

---

## 5. Keamanan

### 5.1 Yang tidak boleh ada di aplikasi (repo, binary, atau `--dart-define`)
- `SUPABASE_SERVICE_ROLE_KEY` (dipakai `api/*.ts`, `create_demo_user.ts`, `scripts/*.js`).
- Token Mapbox **secret** (`sk.…`, scope `DOWNLOADS:READ`) — hanya untuk mengunduh SDK saat build.
- Kunci Firebase Admin / service account FCM, kunci APNs `.p8`, keystore Android + password,
  sertifikat/profil iOS, `GoogleService-Info.plist`/`google-services.json` **boleh** di app
  (bukan rahasia) tetapi jangan di repo publik.
- Kredensial akun demo/test.

### 5.2 Di mana tiap rahasia/konfigurasi tinggal

| Nilai | Boleh di app? | Tempat |
|---|---|---|
| Supabase URL + **anon key** | Ya (publik) | `--dart-define-from-file=env/prod.json` (tidak di-commit), flavor dev/prod |
| Mapbox **public** token (`pk.…`) | Ya | `--dart-define`; **buat token terpisah untuk mobile** tanpa URL restriction (token web yang dibatasi URL sesuai `SECURITY.md` §2 tidak bekerja di SDK native), scope minimal |
| Mapbox **secret downloads** token | **Tidak** | Android: `~/.gradle/gradle.properties` (`MAPBOX_DOWNLOADS_TOKEN`) atau secret CI; iOS: `~/.netrc` (`machine api.mapbox.com login mapbox password sk…`) atau secret CI |
| Service role key | **Tidak** | Hanya env Vercel / Supabase Edge Function |
| FCM server credential | **Tidak** | Secret Supabase Edge Function |
| Sesi user (access/refresh token) | Ya | `flutter_secure_storage` (Keychain/Keystore), bukan SharedPreferences |
| Kontak darurat, outbox S.O.S, track lokal | Ya | drift (SQLite) di sandbox app; pertimbangkan enkripsi (sqlcipher) karena berisi lokasi |

### 5.3 Asumsi RLS yang diandalkan app
1. User tidak bisa mengubah baris `profiles` sendiri (tidak ada policy UPDATE/INSERT sejak
   `20261023000000_restrict_profile_self_update.sql:5`); plan/role/`is_admin`/`can_use_sos`/
   `storage_limit_mb` hanya lewat service role. **Terverifikasi di migration.**
2. Batas jumlah marked locations/areas, offline map (metadata), kuota storage, izin rekam
   track, izin share, izin S.O.S, dan semua aksi admin ditegakkan server (trigger/RLS/RPC,
   §2.7). App tetap mengecek di klien hanya untuk UX.
3. Tabel S.O.S, link, `account_requests`, `login_events`, `reviews` tidak bisa ditulis
   langsung oleh klien.
4. `open_*_link` boleh dipanggil dengan anon key tanpa sesi.
5. App **tidak** boleh memakai `user_metadata` untuk otorisasi apa pun (bisa diubah user sendiri).

### 5.4 Temuan (yang bisa dieksploitasi klien mobile/hasil dekompilasi)

Kunci anon dan URL Supabase akan ada di binary app, jadi anggap semua penyerang bisa
memanggil PostgREST/Realtime langsung.

- **S1 — Tinggi: channel realtime live tracking tanpa otorisasi.**
  `TrackerService.ts:615-619` memakai channel publik `tracking-room` (tanpa `private: true`);
  tidak ada policy `realtime.messages` di migration mana pun. Siapa pun dengan anon key
  (bahkan tanpa login, tergantung setelan Realtime project) bisa **menerima posisi live semua
  broadcaster** dan **mengirim `location-update` palsu / `heartbeat-request`**. Pembatasan
  "monitor = Enterprise monitor360" hanya di klien (`TrackerService.ts:624,672`). Payload
  `user_id` = bagian lokal email di-uppercase (`TrackerService.ts:745-750,842`) sehingga
  membocorkan awal email. Rekomendasi sebelum live tracking masuk app: channel private +
  RLS `realtime.messages` (terima: `is_monitor()`; kirim: authenticated + plan), payload pakai
  UUID + display name, `battery` asli.
- **S2 — Sedang: gerbang plan live tracking hanya di klien.**
  Policy INSERT `tracker_logs` dan `tracker_activity_sessions` hanya `auth.uid() = user_id`
  (`20240222_fix_tracker_policies.sql:20-25`, `20260423000001_add_tracker_activity_sessions.sql:33-37`);
  akun Free bisa menulis log yang terlihat monitor. `Tracker.md` §2 ("Broadcast hanya
  diizinkan … RLS") tidak sesuai kenyataan. Selain itu `tracker_logs.session_id` tidak dicek
  milik pemanggil → user bisa menambah titik ke sesi orang lain; `get_tracker_activity_sessions`
  menghitung `point_count`/`last_point_at` dengan `LEFT JOIN … ON t.session_id = s.id` saja
  (`20260423000001:100-102`), jadi angka sesi korban bisa dirusak (trail di
  `TrackerHistoryViewer.tsx:153-157` aman karena juga memfilter `user_id`).
- **S3 — Sedang: monitor membaca semua profil.** Policy `Monitors can view all profiles`
  (`20240222_fix_tracker_policies.sql:53-58`) + `is_monitor()` (`20261023000000:24-41`)
  memberi **setiap** akun Enterprise `monitor360` (bukan hanya admin) akses baca semua baris
  `profiles`: email, **phone**, organization, plan, `is_admin`, `can_use_sos`; juga semua
  `tracker_logs`. Pertimbangkan view terbatas (id, email, nama) untuk monitor.
- **S4 — Sedang: password default di repo.** `monitoring@landscape360.app` dengan
  `password123` (`20240218_create_monitor_user.sql:25-26`, `_v2.sql:31-32`,
  `20240218_force_create_auth_user.sql:27-28`) dijadikan Enterprise `monitor360`
  (`20240523000002_fix_monitor_profile.sql`); `monitor@enterprise.com` dan
  `pro_user_N@example.com` `password123` (`20240101000000_seed_demo_users.sql:9,41,64,96`);
  `demo@landscape360.app` / `Demo12345!` (`create_demo_user.ts:17-18`). Jika akun ini ada di
  production dengan password tersebut, siapa pun bisa login sebagai monitor (lihat S1/S3).
  Cek, ganti password atau hapus, dan jangan pakai akun ini untuk review store.
- **S5 — Sedang: enumerasi akun lewat saran share.**
  `marked_location_share_suggestions` (`20261024000017_share_fixes.sql:85-128`): akun Pro/Enterprise
  mana pun bisa mengirim awalan email ≥2 huruf dan mendapat `user_id`, display name, dan email
  tersamar (huruf pertama + domain) **untuk semua akun**; dengan menambah huruf satu per satu
  (`position(v_query IN lower(p.email)) = 1`) email lengkap bisa direkonstruksi. Pesan error
  `share_recorded_track`/`share_marked_locations` juga mengonfirmasi keberadaan email. Usul:
  saran hanya dari penerima sebelumnya / organisasi sama, pencarian email harus persis.
- **S6 — Rendah–Sedang: `display_name` bisa dipalsukan.** User bebas mengubah
  `user_metadata` (`supabase.auth.updateUser({data})`, `AuthControl.tsx:219-221`); nilai ini
  tampil sebagai `owner_name` di `open_marked_location_link`/`open_marked_area_link` kepada
  penerima anonim, di saran share, nama penulis review, dan daftar S.O.S admin
  (`account_display_name`, `20261024000003:57-71`). Risiko penyamaran ("Admin Landscape 360",
  "Basarnas"). Tidak ada gerbang otorisasi yang memakai metadata (bagus).
- **S7 — Info (aman): self-update plan/admin/S.O.S sudah ditutup.** Tidak ada policy
  UPDATE/INSERT `profiles` untuk klien; `update_my_contact` hanya menulis `organization`,
  `phone`, `updated_at` (`20261024000009:28-51`); `can_use_sos` hanya lewat
  `/api/admin-users` (`api/admin-users.ts:438-446`). Tidak ditemukan cara user menaikkan plan,
  role, `is_admin`, atau `can_use_sos` sendiri. (Catatan: `ARCHITECTURE.md` masih
  menggambarkan skema lama.)
- **S8 — Rendah: RPC link tanpa login.** `open_marked_location_link` / `open_marked_area_link`
  (`20261026000018:96-120`, `20261026000019` §5) hanya mengembalikan field yang dimaksud (tanpa
  id, user_id, email); token 32-hex dari `gen_random_uuid()` (122 bit acak) → tidak bisa
  ditebak, tanpa rate limit tapi tidak relevan. Yang ikut terbuka: `contact`, `address`,
  `description`, nama pemilik — sesuai desain, tapi beri tahu user di UI. Integritas:
  `ring` hanya dicek tipe array & panjang 3–500, elemen tidak divalidasi, dan `area_m2`/
  `perimeter_m` dikirim klien (`markedAreaSync.ts:44-51`) → pemilik bisa menerbitkan angka
  palsu atau ring rusak; **app harus mem-parse ring dari link secara defensif** (abaikan
  elemen bukan `[num, num]` dalam rentang) dan sebaiknya menghitung ulang luas/keliling.
- **S9 — Rendah: kuota basemap bisa diakali.** Kuota memakai `custom_basemaps.file_size`
  yang dikirim klien (`useCustomBasemapStore.ts:516`) dan pemilik boleh UPDATE baris itu
  (policy `Users can update own basemaps`, `20261024000006:52-57`, tanpa kunci kolom) → set
  `file_size` kecil/0. Objek storage juga bisa diunggah tanpa baris (policy hanya cek folder +
  plan), maks 10 MB per file tanpa batas jumlah. Hanya Enterprise/admin.
- **S10 — Rendah: batas yang hanya di klien.** Jumlah survei 2/4/10
  (`useSurveyStore.ts:343-361`) dan unduhan tile offline (trigger hanya cek baris metadata
  `offline_maps`, nilai `size_est_mb` dari klien) bisa dilewati klien modifikasi; dampaknya
  biaya Mapbox / storage. App tetap menegakkan batas yang sama.
- **S11 — Rendah: cek password lama hanya di klien.** `changeMyPassword`
  (`lib/accountPassword.ts:21-38`) memverifikasi dengan `signInWithPassword` lalu
  `updateUser({password})`; tanpa setelan Supabase "Secure password change / reauthentication",
  sesi yang dicuri bisa mengganti password langsung. Aktifkan setelan itu (Q12).
- **S12 — Rendah: flood guard account request global.** `MAX_REQUESTS_PER_HOUR = 30` untuk
  **semua** pengunjung (`api/account-requests.ts:33,128-136`) → satu penyerang bisa memblokir
  request asli selama satu jam; tidak ada limit per IP / captcha. App memakai endpoint yang sama.
- **S13 — Info: `sos_report` tanpa rate limit.** Akun ber-izin S.O.S bisa membuat alert/titik
  tanpa batas (`sos_alert_points` tidak punya CHECK lat/lng, `20261024000015:33-40`);
  `p_started_at` bebas di masa lalu. Dampak kecil (akun terpercaya).
- **S14 — Info: helper SECURITY DEFINER tidak di-REVOKE dari anon.** `is_admin()`,
  `is_monitor()`, `can_use_track_recorder()`, `can_share_marked_locations()`,
  `is_marked_location_owner()`, `is_recorded_track_owner()`, `mask_email()`,
  `get_tracker_sessions()`, `get_tracker_activity_sessions()`, `delete_old_tracker_logs()`
  bisa dipanggil anon tetapi hanya mengembalikan data milik `auth.uid()` (kosong untuk anon).
  Tidak berbahaya; boleh dirapikan.
- **S15 — Perlu dicek: sign-up publik.** Migration tidak menunjukkan apakah "Enable email
  signups" di Supabase Auth dimatikan. Jika aktif, siapa pun dengan anon key bisa
  `auth.signUp()` dan langsung mendapat akun Free (trigger `handle_new_user`) tanpa melalui
  Account Requests. Pastikan dimatikan (Q13).

---

## 6. Risiko & pertanyaan untuk pemilik

Mohon jawab (✅/❌/isian) sebelum Fase 1.

| # | Pertanyaan / risiko | Usulan |
|---|---|---|
| Q1 | Skema production mungkin beda dari migration (urutan tidak linier, seed tidak idempoten). | Izinkan saya meminta dump skema + policy production (tanpa data) untuk diverifikasi. |
| Q2 | **App ID final** (tidak bisa diubah setelah rilis). | `id.co.jcdigital.landscape360` (iOS bundle ID & Android applicationId); flavor dev `id.co.jcdigital.landscape360.dev` dengan nama "Landscape 360 Dev". Pemilik akun Apple Developer & Play Console: perorangan atau organisasi JC Digital (organisasi butuh D-U-N-S)? |
| Q3 | **Push S.O.S**: FCM (Android + iOS via APNs) disetujui? Perlu project Firebase, kunci APNs, tabel baru `device_push_tokens(user_id, token, platform, updated_at)` dengan RLS milik sendiri, dan Edge Function/Database Webhook pada INSERT `sos_alerts` (dan update pesan?) yang mengirim ke token admin. Hanya ada satu admin (`profiles_single_admin`): apakah monitor360 Enterprise juga perlu menerima push? | FCM + Edge Function; penerima: admin saja di v1. |
| Q4 | **Live tracking** di web disembunyikan flag `VITE_ENABLE_GPS_TRACKER` (`ControlPanel.tsx:831`). Apakah aktif di production? Jika ya, perbaikan S1/S2 harus dilakukan sebelum app membawanya. | Tunda live tracking (broadcast/monitor/Record Activity) ke "app nanti" kecuali flag aktif dan S1 diperbaiki. |
| Q5 | **Universal links / App Links** untuk `https://landscape360.jcdigital.co.id/?at=…`, `?place=…`, `?area=…`. Perlu `public/.well-known/apple-app-site-association` (disajikan `application/json`, tanpa ekstensi — perlu header di `vercel.json`) dan `assetlinks.json` (SHA-256 sertifikat upload **dan** Play App Signing). Semua path `/` akan terbuka di app — setuju hanya untuk query tersebut? | AASA `components` dengan `"?": {"at": "*"}` dst.; Android intent-filter path `/` + penanganan di app (yang bukan link share dibuka di browser). |
| Q6 | **GPS background**: `flutter_background_geolocation` (Transistorsoft) butuh lisensi berbayar untuk build release Android; alternatif gratis (`geolocator` + foreground service sendiri / `background_location`) lebih banyak kerja dan kurang andal di iOS. | Putuskan anggaran lisensi; saya usul coba alternatif gratis di Fase 6 dengan kriteria uji 30 menit layar mati. |
| Q7 | **Biaya Mapbox mobile** dihitung per MAU (+ unduhan offline tile packs); token web dibatasi URL tidak bisa dipakai. | Buat token mobile terpisah; cek perkiraan biaya; tetapkan batas unduhan offline sama dengan web. |
| Q8 | Izin lokasi "Always" (Play: formulir deklarasi background location + video; Apple: alasan kuat). | Minta hanya saat mulai rekam track / S.O.S; siapkan video demo. |
| Q9 | **Hapus akun sendiri** (wajib App Store 5.1.1(v) & Play): butuh endpoint baru di `api/` + halaman `/delete-account`. Admin tidak boleh menghapus diri. | Setuju dibuat di Fase 8. |
| Q10 | Akun untuk App Review (Apple/Google butuh login). Jangan pakai akun di S4. | Buat akun review baru (Pro, tanpa S.O.S atau dengan S.O.S yang tidak membangunkan admin di malam hari?). |
| Q11 | S.O.S dari app akan memicu admin sungguhan. Perlu mode uji (mis. pesan "TEST") atau project Supabase staging? | Project Supabase staging untuk flavor dev. Ada? |
| Q12 | Aktifkan "Secure password change" Supabase (S11)? | Ya. |
| Q13 | Pastikan sign-up publik di Supabase Auth dimatikan (S15). | Mohon dicek. |
| Q14 | Kontur: hitung di klien seperti web (TurfContourProvider) atau pakai tileset kontur Mapbox (lebih ringan, tampilan sedikit beda)? | Tileset Mapbox. |
| Q15 | Cuaca BMKG di web memakai `adm4` tetap (Jakarta Pusat). Ikuti web, atau pakai lokasi user (perlu tabel kode adm4)? | Ikuti web di v1. |
| Q16 | Export laporan PNG/JPG/PDF masuk v1 (Fase 7) atau nanti? Di web komponen `ScreenshotControl` sedang di-comment (`MapDashboard.tsx:4`). | Nanti, kecuali sering dipakai. |
| Q17 | Survei offline: web memakai last-write-wins (`updated_at` dari klien). Edit di web dan app bersamaan bisa saling menimpa. | Terima LWW di v1, beri peringatan bila `updated_at` server lebih baru. |
| Q18 | Kontak darurat S.O.S hanya di perangkat (tidak sinkron). Tetap begitu? | Ya (privasi), tapi tampilkan pengingat setelah login di HP baru. |
| Q19 | Admin mengelola via web; apakah admin perlu peta S.O.S dengan jejak (`sos_alert_points`) di app? | Ya, data sudah bisa dibaca RLS. |
| Q20 | Perbaikan keamanan S1–S6, S9, S11–S12 menyentuh backend web; boleh dijadwalkan sebagai pekerjaan web terpisah? | Ya, minimal S1 (bila Q4 = ya), S4, S5. |
| Q21 | Versi OS minimum. | Android 8.0 (API 26), iOS 15 (cek syarat `mapbox_maps_flutter` terbaru). |
| Q22 | Crash reporting: Sentry atau Firebase Crashlytics? Data lokasi tidak boleh ikut ke laporan crash. | Crashlytics (karena Firebase sudah dipakai untuk FCM). |

Risiko lain: biaya pemeliharaan dua codebase; perubahan migration web di masa depan harus
kompatibel ke belakang dengan app yang sudah terpasang (app lama bisa bertahan berbulan-bulan);
store review menolak S.O.S yang terkesan menggantikan layanan darurat resmi (teks harus jelas
bahwa 112/115 tetap jalur utama).

---

## 7. Hal di `Task.md` yang tidak sesuai dengan kode web

1. **"Marked Areas: luas & keliling WGS84"** — hanya keliling yang Vincenty WGS84; luas
   memakai `@turf/area` pada **bola** R = 6371008.8 m (`utils/markedAreas.ts:25-26`,
   `node_modules/@turf/helpers` v7.3.3). Port harus meniru turf agar angka identik.
2. **"Geodesi: jangan pakai haversine"** — Track Recorder dan live tracking memakai haversine
   R = 6 371 000 m (`utils/trackRecorderGeo.ts:6-19`, `TrackerService.ts:238-252`), dan
   `snapToAngle` memakai turf bola. Untuk hasil identik, fungsi-fungsi itu harus di-port
   dengan rumus yang sama; Vincenty hanya untuk Navigator & keliling area.
3. **"Track Recorder: … lihat & share semua akun login"** — semua akun login bisa *melihat*
   dan *menerima* share, tetapi *membagikan* hanya Enterprise/admin
   (`share_recorded_track` + policy INSERT, `20261024000001:60-70,105-110`; `TrackRecorder.md` §Berbagi).
4. **Live tracking** sebagai fitur web: di web tersembunyi di balik
   `VITE_ENABLE_GPS_TRACKER` (`ControlPanel.tsx:831`) dan gerbang plannya tidak ditegakkan
   server (S1, S2), berbeda dengan klaim `Tracker.md` §2.
5. **`src/lib/adminEmail.ts (planBroadcast)` di daftar port** — Broadcast adalah fitur admin
   web saja; tidak perlu di-port untuk v1.
6. **S.O.S admin** — web tidak memakai realtime; banner/daftar admin di-*poll* tiap 30 detik
   (`SosAdminLayer.tsx:8`, `SosAlertsPanel.tsx:44`). Tombol S.O.S di peta disembunyikan untuk
   admin (`SosButton.tsx:62`), admin memakai S.O.S dari User Account.
7. **Export laporan** — tercantum sebagai fitur web, tetapi `ScreenshotControl` sedang
   di-comment di `MapDashboard.tsx:4` (Q16).
8. `ARCHITECTURE.md` (skema `TRACKING_LOGS` PostGIS, `full_name` di profiles, harga plan)
   sudah usang dibanding migration; jangan dipakai sebagai acuan skema.
