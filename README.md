# gdrive-sync — Sync folder laptop ↔ Google Drive (Linux)

[![tests](https://github.com/mteguhfh/gdrive-sync/actions/workflows/test.yml/badge.svg)](https://github.com/mteguhfh/gdrive-sync/actions/workflows/test.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Pakai [rclone](https://rclone.org) + systemd user timer. Script ini tidak butuh daemon
tambahan: tiap `INTERVAL` (default 5 menit) folder lokal dan folder di Drive disamakan.

Butuh **rclone >= 1.66** (flag `--resync-mode`, `--conflict-resolve`, `--max-lock`).
Cek: `rclone version`. Kalau distro masih kasih versi lama, install dari
<https://rclone.org/install/>.

## Quick start

```bash
cd ~/Documents/GDrive_Linux

# 1. Setup: bikin config + login Google (browser kebuka, klik "Allow")
./gdrive-sync.sh setup

# 2. (opsional) edit config: folder lokal, folder Drive, mode, interval
nano ~/.config/gdrive-sync/gdrive-sync.conf

# 3. Coba dulu tanpa ngubah apa-apa
./gdrive-sync.sh sync --dry-run

# 4. Sync beneran sekali
./gdrive-sync.sh sync

# 5. Pasang auto-sync (systemd timer)
./gdrive-sync.sh install
./gdrive-sync.sh status
```

Default: `~/GDrive` di laptop ↔ folder `Laptop` di My Drive, dua arah.

## Command

| Command | Fungsi |
|---|---|
| `setup` | Buat config, buat remote rclone `gdrive` (OAuth), bikin folder lokal & Drive |
| `sync [--dry-run] [--resync] [--force]` | Sync sekali sekarang |
| `install` / `uninstall` | Pasang / copot auto-sync (systemd user timer). File tidak disentuh |
| `add-folder <path>` | Tambah folder ke backup (otomatis `MODE=backup`) |
| `remove-folder <path>` | Hapus folder dari daftar backup |
| `folders` | Lihat daftar folder backup |
| `status` | Status timer + 20 baris log terakhir |
| `logs` | `tail -f` log |
| `config` | Tampilkan config aktif |

## Mode

- **`bisync`** (default) — dua arah. Edit/hapus di laptop atau di Drive (web/HP), dua-duanya ikut.
  - Run pertama = *baseline*: isi kedua sisi digabung, versi **terbaru** menang, **tidak ada yang dihapus**.
  - Konflik (file diubah di dua sisi): versi terbaru menang, versi lain disimpan dengan nama `*.conflict1`.
  - Kalau `filters.txt` diubah, baseline diulang otomatis sekali.
  - Kalau rclone abort keras (error berulang), run berikutnya otomatis re-baseline. Efek sampingnya:
    file yang dihapus di satu sisi sebelum abort bisa muncul lagi (data aman, tidak hilang).
  - Safety bawaan rclone: kalau >50% file akan terhapus dalam satu run, sync dibatalkan.
- **`push`** — satu arah laptop → Drive (Drive jadi cermin). File yang dihapus di laptop
  masuk **Trash** Google Drive (bisa di-restore 30 hari). Perubahan di Drive **ditimpa**,
  termasuk file yang hanya ada di Drive akan dihapus. Cocok kalau Drive hanya dipakai
  sebagai salinan laptop, bukan tempat kerja.
- **`backup`** — satu arah laptop → Drive tanpa hapus (`rclone copy`). File yang dihapus
  di laptop tetap ada di Drive. File yang hanya ada di Drive juga tidak disentuh. Ini mode
  paling aman untuk cadangan.

## Backup beberapa folder

`MODE=backup` bisa mem-backup banyak folder sekaligus. Tambah/hapus tanpa edit config:

```bash
./gdrive-sync.sh add-folder ~/Documents
./gdrive-sync.sh add-folder ~/Pictures
./gdrive-sync.sh folders
./gdrive-sync.sh remove-folder ~/Pictures
```

Daftar disimpan di `~/.config/gdrive-sync/sources.txt` (satu path per baris). Tiap folder
jadi subfolder di Drive: `Laptop/Documents`, `Laptop/Pictures`, dan seterusnya.
Nama folder harus unik. Kalau daftar kosong, sync berhenti supaya tidak salah menyalin
folder default.

Backup jalan paralel per subfolder tingkat atas (`PARALLEL_JOBS`, default 4). rclone
membuat folder di Drive satu per satu (~1 folder/detik per proses), jadi 4 proses paralel
kira-kira 4x lebih cepat. Upload pertama yang besar bisa berjam-jam; setelah itu
sync berikutnya cepat karena file yang sudah sama dilewati.

## Membuat client ID Google sendiri

rclone memakai client ID bersama milik rclone, dan Google mempensiunkannya selama 2026.
Untuk pemakaian jangka panjang, buat client ID sendiri (gratis, sekali saja):

1. <https://console.cloud.google.com/projectcreate> → buat project.
2. **APIs & Services → Library** → aktifkan **Google Drive API**.
3. **OAuth consent screen** → isi nama app, email, domain situs ini, privacy policy:
   - Home: `https://mteguhfh.github.io/gdrive-sync/`
   - Privacy: `https://mteguhfh.github.io/gdrive-sync/privacy.html`
4. **Credentials → Create credentials → OAuth client ID → Desktop app**.
5. Simpan Client ID + secret, lalu:
   ```bash
   rclone config update gdrive client_id=... client_secret=...
   rclone config reconnect gdrive:
   ```
   atau `./gdrive-sync.sh setup` lalu pilih buat remote baru.

## Catatan

- **`bisync` ke root My Drive diblokir.** Set `REMOTE_PATH` ke subfolder (mis. `Laptop`).
  Kalau memang mau seluruh Drive dua arah, set `GDRIVE_SYNC_ALLOW_ROOT=1`.
- Google Docs/Sheets/Slides native **di-skip** (bukan file biasa; tetap aman di Drive).
- Exclude default ada di [`filters.txt`](filters.txt): `node_modules`, `.next`, `build`, `dist`,
  `target`, cache dev, `*.tmp`, lock file Office, dll. Pola berlaku di semua level folder.
- `filters.txt.md5` dibuat otomatis oleh rclone (hash filter). Jangan dihapus; kalau pakai git,
  masukkan ke `.gitignore`.
- Rename file di bisync dihitung sebagai hapus + tambah, jadi file bisa terunduh ulang.
- Log: `~/.local/state/gdrive-sync/gdrive-sync.log` (rotate otomatis di 10 MB, mode 600).
- Gagal sync → notifikasi desktop (`notify-send`) + exit non-zero (kelihatan di `systemctl --user status gdrive-sync`).
- Timer jalan saat kamu login. Biar jalan tanpa login: `loginctl enable-linger $USER`.
- Batasi bandwidth: di config `EXTRA_FLAGS=(--bwlimit 2M)`.
- Bukan real-time: perubahan naik/turun paling lambat ±`INTERVAL`. Mau sekarang? `./gdrive-sync.sh sync`.

## Test

```bash
./tests/run_tests.sh
```
Test pakai folder lokal sebagai "remote" palsu (tanpa akun Google): baseline, sync dua arah,
konflik, dry-run, filter, lock, mode push/backup, guard root, recovery setelah error,
generate unit systemd, rotasi log, validasi config.

## Kontribusi

Pull request dan issue terbuka untuk siapa saja. Baca [CONTRIBUTING.md](CONTRIBUTING.md)
sebelum kirim perubahan: cara jalanin test, aturan gaya bash, dan format commit.

- Situs: <https://mteguhfh.github.io/gdrive-sync/>
- Kebijakan privasi: <https://mteguhfh.github.io/gdrive-sync/privacy.html>
- Lisensi: [MIT](LICENSE)
