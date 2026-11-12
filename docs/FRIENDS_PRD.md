# PRD: Friends & Chat (Landscape 360)

Status: **dibangun** (aplikasi; web dan database diserahkan di `docs/backend/friends/`) · 11 November 2026 · grup, balasan dan web khusus aplikasi: 12 November 2026 (bagian 15)

## 1. Ringkasan

Pengguna Landscape 360 bisa saling menambahkan sebagai **teman**, lalu **mengirim pesan** satu sama lain.
Pesan **tidak real-time**: aplikasi memeriksa pesan baru secara berkala, bukan lewat koneksi yang terus terbuka.
Selain teks, pesan bisa membawa **lokasi saya**, atau **titik / track / area dari peta**, yang dibuka penerima
langsung di peta.

## 2. Masalah

- Sesama pendaki yang bertemu di basecamp atau di event club tidak punya cara terhubung di dalam aplikasi.
  Mereka pindah ke WhatsApp dan kehilangan konteks peta.
- Berbagi titik atau jalur ke satu orang saat ini harus lewat link share atau email track. Itu terlalu banyak
  langkah untuk percakapan sehari-hari.
- Club dan Community bersifat kelompok atau publik. Belum ada jalur pribadi satu-ke-satu.

## 3. Tujuan dan ukuran keberhasilan

| Tujuan | Ukuran |
|---|---|
| Mudah terhubung | Menambah teman di basecamp (lewat QR) selesai < 20 detik |
| Percakapan berguna di lapangan | ≥ 30% percakapan memuat lokasi atau data peta |
| Tetap ringan | Ukuran aplikasi bertambah < 1 MB; tidak ada proses jaringan di latar belakang |
| Tanpa sinyal tetap bisa menulis | Pesan yang ditulis tanpa sinyal terkirim otomatis saat online |

## 4. Pengguna

- Pendaki yang bertemu di jalur, basecamp, atau open trip.
- Anggota club yang ingin bicara empat mata (misalnya ketua dengan peserta event).
- Tim SAR / pengelola yang mengirim titik ke satu orang.

## 5. Lingkup

### MVP

1. **Daftar teman** dengan nama tampilan (nama depan + inisial, sama seperti Community) dan organisasi
   bila diisi.
2. **Menambah teman** lewat:
   - **email** akun Landscape 360; atau
   - **link / QR teman**: setiap akun punya link pribadi, dan siapa pun yang membukanya bisa mengirim
     permintaan pertemanan. Link bisa diganti untuk mematikan yang lama.
   - Tidak ada pencarian nama bebas, supaya daftar pengguna tidak bisa ditelusuri orang asing.
3. **Permintaan pertemanan**: Terima / Tolak. Teman bisa dihapus kapan saja.
4. **Chat satu-ke-satu** antar teman:
   - teks (maks. 2.000 karakter);
   - **lokasi saya** (satu titik GPS, bukan live);
   - **lampiran peta**: track, area, lokasi tersimpan, atau Field Work Classic, dengan cara yang sama seperti
     lampiran Community (salinan).
5. **Status pesan**: terkirim, dibaca. **Badge** jumlah pesan belum dibaca.
6. **Tanpa sinyal**: pesan masuk antrean di HP dan terkirim otomatis saat online. Percakapan terakhir bisa
   dibaca offline.

### Sebelum rilis di App Store / Play Store (ditunda di tahap ini)

- **Blokir** pengguna dan **Laporkan** pesan atau pengguna (wajib untuk aplikasi dengan konten antar pengguna:
  App Store Review Guideline 1.2, Google Play User Generated Content).
- Tinjauan laporan oleh admin.
- Notifikasi push (butuh Firebase dan Apple Developer Program berbayar).
- Pembaruan Privacy Policy dan Terms.

### Setelah MVP

- Chat grup di luar club.
- Foto di chat.
- Status "online / terakhir terlihat".

## 6. Cerita pengguna (MVP)

1. Di basecamp, saya membuka **QR teman** saya. Teman baru memindainya dengan kamera HP, aplikasinya terbuka,
   dan ia menekan **Add friend**.
2. Saya menerima permintaan pertemanan, lalu teman itu muncul di daftar teman.
3. Saya mengirim **"Kumpul di sini jam 5"** beserta **lokasi saya**. Teman saya membukanya dan langsung melihat
   titiknya di peta.
4. Setelah turun, saya mengirim **track** saya ke teman yang tertinggal di jalur.
5. Di pos tanpa sinyal, saya menulis pesan. Pesan itu terkirim sendiri begitu ada sinyal.
6. Saat membuka aplikasi, saya melihat badge **3** di Friends karena ada pesan baru.

## 7. Aturan per paket (usulan)

| | Tamu | Free | Pro | Enterprise | Admin |
|---|---|---|---|---|---|
| Menambah teman dan chat teks | — | ✓ | ✓ | ✓ | ✓ |
| Kirim lokasi saya | — | ✓ | ✓ | ✓ | ✓ |
| Kirim lampiran peta (track, area, lokasi, Field Work) | — | — | ✓ | ✓ | ✓ |
| Maks. teman | — | 100 | 300 | 1.000 | — |
| Pesan per hari | — | 200 | 1.000 | 3.000 | — |
| Permintaan pertemanan per hari | — | 20 | 50 | 100 | — |

Prinsip: mengirim lokasi adalah informasi keselamatan, jadi akun Free tetap bisa. Lampiran peta mengikuti
aturan Community (Pro ke atas).

## 8. Rincian MVP

### 8.1 Letak di aplikasi

- **User Account → Friends**, dengan badge pesan belum dibaca. Badge yang sama tampil di avatar akun pada
  sheet peta.
- Halaman **Friends** punya dua tab: **Chats** (percakapan terbaru di atas) dan **Friends** (daftar teman dan
  permintaan masuk).
- Tombol **Add friend**: isi email, pindai QR, atau bagikan link / QR saya.
- Dari profil anggota club dan penulis postingan Community: **Add friend** (setelah MVP, bila diinginkan).

### 8.2 Menambah teman

- **Email**: server mencari akun dengan email itu. Jawabannya sama untuk email yang ada maupun yang tidak ada
  ("Permintaan terkirim bila akun ditemukan"), supaya tidak bisa dipakai untuk mengecek email terdaftar.
- **Link / QR**: `/?friend=<token>`. Token 32 karakter acak, bisa diganti kapan saja. Membuka link tanpa akun
  menampilkan kartu nama dan ajakan login.
- **Permintaan**: tertunda sampai diterima atau ditolak, dan kedaluwarsa setelah 30 hari. Menolak tidak
  memberi tahu pengirim. Dua orang yang saling mengirim permintaan langsung berteman.

### 8.3 Chat

- Hanya antar teman. Menghapus teman membuat chat tidak bisa dikirim lagi, tapi riwayat tetap terbaca oleh
  keduanya.
- **Pesan**: teks dibersihkan dari HTML, maks. 2.000 karakter. Lokasi berupa satu titik (lat, lng, akurasi,
  waktu). Lampiran peta disimpan sebagai salinan, seperti Community.
- **Menghapus pesan**: pengirim bisa menghapus pesannya sendiri dalam 1 jam ("Pesan dihapus").
- **Dibaca**: ditandai saat penerima membuka percakapan.
- **Pemuatan**: 30 pesan terakhir, lalu lebih lama secara bertahap (pagination kursor).

### 8.4 Pemeriksaan pesan baru (tidak real-time)

| Keadaan | Frekuensi |
|---|---|
| Layar chat terbuka | setiap 15 detik |
| Halaman Friends terbuka | setiap 30 detik |
| Aplikasi dibuka / kembali ke depan | sekali (untuk badge) |
| Aplikasi di latar belakang | tidak ada |

Satu pemeriksaan = satu panggilan RPC kecil (`my_chat_updates(since)`) yang hanya mengembalikan yang berubah.

### 8.5 Tanpa sinyal

- Pesan yang ditulis tanpa sinyal tampil dengan tanda jam, tersimpan di HP, dan dikirim otomatis saat online.
  Polanya sama dengan antrean Community.
- Percakapan terakhir (50 pesan per teman) disimpan di HP untuk dibaca offline.

### 8.6 Privasi dan keamanan

- Isi chat hanya bisa dibaca kedua peserta, dan tidak bisa dibaca admin lewat aplikasi.
- Email tidak pernah tampil; nama tampil sama dengan Community.
- Lokasi hanya dikirim saat pengguna menekan **Kirim lokasi saya**, tidak pernah otomatis.
- Data chat ikut terhapus saat akun dihapus (`DELETE /api/account`).
- Batas harian ditegakkan di database.

## 9. Data dan backend (Supabase)

| Tabel | Isi |
|---|---|
| `friend_links` | user_id, token (unik), created_at |
| `friend_requests` | id, from_id, to_id, status (pending / accepted / declined), created_at, decided_at |
| `friendships` | user_a, user_b (user_a < user_b), created_at |
| `chat_messages` | id, sender_id, recipient_id, body, kind (text / location / attachment), data jsonb, client_id (unik, untuk antrean offline), created_at, read_at, deleted_at |

- **RLS**: setiap tabel hanya terbaca oleh pihak yang terlibat. Semua tulisan lewat fungsi `SECURITY DEFINER`
  yang mengecek pertemanan, paket, dan batas harian (pola yang sama dengan Community).
- **RPC**:
  - `send_friend_request(p_email)`, `request_friend_by_link(p_token)`, `answer_friend_request(p_id, p_accept)`
  - `remove_friend(p_user_id)`, `my_friend_link()`, `renew_friend_link()`
  - `my_friends()`, `my_friend_requests()`
  - `send_chat_message(p_to, p_kind, p_body, p_data, p_client_id)`: idempoten lewat `client_id`, sehingga
    antrean offline tidak mengirim dua kali.
  - `chat_messages(p_with, p_before)`, `mark_chat_read(p_with)`, `delete_chat_message(p_id)`
  - `my_chat_updates(p_since)`: percakapan yang berubah dan jumlah belum dibaca.
- **Indeks**: `(recipient_id, read_at)` untuk badge; `(least(sender,recipient), greatest(...), created_at)`
  untuk riwayat.
- **Ukuran**: satu pesan teks ±0,5 KB. 10.000 pesan per hari ≈ 5 MB per hari.

## 10. Kebutuhan non-fungsional

- Ukuran aplikasi bertambah < 1 MB. Tidak ada paket baru, kecuali pemindai QR bila dipilih (±1–2 MB; lihat
  bagian 13).
- Tidak ada pekerjaan jaringan saat aplikasi di latar belakang; baterai tidak terpengaruh.
- Membuka percakapan < 1 detik di 4G.
- Bahasa antarmuka mengikuti aplikasi (Inggris).

## 11. Risiko

| Risiko | Mitigasi |
|---|---|
| Spam / pelecehan | Hanya teman yang bisa chat; batas harian; Blokir dan Laporkan sebelum rilis toko |
| Pesan "tidak sampai" karena tidak real-time | Pemeriksaan 15 detik saat chat terbuka; status terkirim / dibaca |
| Tidak tahu ada pesan baru (tanpa push) | Badge saat aplikasi dibuka; push saat akun berbayar siap |
| Kebocoran email lewat Add friend | Jawaban sama untuk email ada / tidak ada; tidak ada pencarian nama |
| Data pribadi (UU PDP) | Hanya peserta yang membaca; hapus bersama akun; Privacy Policy diperbarui sebelum rilis |

## 12. Rencana kerja

| Tahap | Isi | Perkiraan |
|---|---|---|
| 1. Backend | Migration tabel, RLS, RPC, batas harian; diuji di Postgres | 0,5–1 hari |
| 2. Mobile | Friends, Add friend (email, link, QR), permintaan, chat, lokasi, lampiran, antrean offline, badge | 2 hari |
| 3. Web (opsional) | Komponen siap-salin di `docs/backend/friends/` | 1–2 hari |
| 4. Sebelum rilis toko | Blokir, Laporkan, tinjauan admin, Privacy Policy, push | menyusul |

## 13. Keputusan (11 November 2026)

1. **Web** ikut di tahap ini (komponen siap-salin di `docs/backend/friends/`).
2. **Menambah teman**: email dan link / QR saja, tanpa pencarian nama.
3. **Paket**: sesuai bagian 7 (semua akun chat dan kirim lokasi; lampiran peta Pro ke atas).
4. **Pemindai QR**: memakai `mobile_scanner` di aplikasi; QR dibuat dengan `qr_flutter` (aplikasi) dan `qrcode` (web).
5. Blokir / Laporkan, push, dan Privacy Policy ditunda sampai sebelum rilis toko.

## 14. Nama fungsi akhir

`my_chat_updates` di bagian 9 menjadi dua fungsi: `my_chat_unread()` untuk badge, dan
`chat_messages(p_with, p_before, p_since)` yang dengan `p_since` hanya mengembalikan pesan yang
berubah (baru, dibaca, dihapus) untuk chat yang sedang terbuka.

## 15. Grup, balasan, dan chat khusus aplikasi (12 November 2026)

Migration `20261112000033_chat_groups.sql`, di atas migration 0032.

### 15.1 Chat Club

- Dibuka oleh **Ketua Club** (tombol *Open a club chat* di halaman club; perlu akun Enterprise
  seperti pengelolaan club lainnya). Satu per club; membuka lagi memakai yang sama.
- Anggotanya **mengikuti keanggotaan club**: tidak ada tambah / hapus anggota; keluar dari club
  berarti keluar dari chatnya. Anggota club melihat tombol *Club chat* setelah dibuka.
- Ketua Club bisa menghapus pesan siapa pun kapan saja, dan menghapus chat club (beserta semua
  pesannya). Hilang bersama club.

### 15.2 Grup baru

- Dibuat oleh akun **Pro ke atas** (Friends → Groups → *New group*): nama 2–60 huruf, lalu pilih
  teman. Akun Free tidak bisa membuat, tapi bisa menjadi anggota.
- **Hanya pembuat grup** yang menambah anggota, dan hanya **teman yang sudah saling berteman**
  dengannya. Pembuat juga mengganti nama, mengeluarkan anggota, menghapus pesan siapa pun, dan
  menghapus grup. Anggota lain bisa keluar sendiri; pembuat tidak bisa keluar (hapus grupnya).
- Batas: Pro **10 grup, 50 anggota** per grup; Enterprise 30 / 200; admin tanpa batas.

### 15.3 Pesan grup

- Tabel `chat_messages` yang sama, dengan `group_id` (bukan `recipient_id`). Jenis pesan,
  batas harian, dan aturan lampiran peta sama dengan chat pribadi.
- "Dibaca" di grup per anggota (`chat_group_reads.last_read_at`, diperbarui saat grup dibuka),
  bukan per pesan; tidak ada centang dua di grup. Belum dibaca = pesan orang lain setelah itu.
- Setiap pesan menampilkan nama pengirim; header membuka daftar anggota.

### 15.4 Balasan (reply)

- Kolom `reply_to` di `chat_messages`; harus pesan dari percakapan yang sama. Berlaku di chat
  pribadi dan grup, juga saat dikirim dari antrean offline.
- Pembacaan menyertakan kutipan: siapa, jenis, 120 huruf pertama, atau "Message deleted" bila
  pesan asal sudah dihapus. Di aplikasi: tekan lama → *Reply*; bar balasan di atas kotak pesan.

### 15.5 Web

Web tetap menampilkan tombol Friends, daftar Chats dengan jumlah belum dibaca, permintaan
pertemanan, QR dan Add friend. Membuka sebuah chat di web menampilkan pemberitahuan bahwa chat
(pesan, lokasi, data peta, grup, balasan) **hanya di aplikasi**. Komponen chat di web dihapus.

### 15.6 Fungsi baru

`create_chat_group`, `create_club_chat`, `club_chat_group`, `add_chat_group_members`,
`remove_chat_group_member`, `rename_chat_group`, `delete_chat_group`, `my_chat_groups`,
`chat_group_members`, `send_group_message`, `group_messages`, `mark_group_read`.
Berubah: `send_chat_message` (+ `p_reply_to`), `chat_messages` (+ kolom kutipan),
`delete_chat_message` (pembuat grup / Ketua Club), `my_chat_unread` (ikut grup),
`friends_limits` (+ `groups`, `group_members`).
