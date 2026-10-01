# 9Router VPS Installer

Satu script untuk menjadikan VPS Ubuntu sebagai pintu publik yang **stabil** untuk 9Router —
menggantikan tunnel gratisan (localhost.run dkk) yang domainnya ganti-ganti.

## Install

Salin perintah di bawah (klik tombol copy di pojok kanan blok kode), paste di VPS Ubuntu:

```bash
curl -fsSL https://raw.githubusercontent.com/zal-m10/9router-vps/main/install.sh -o install.sh && sudo bash install.sh
```

Mode non-interaktif (langsung sebut domain + port):

```bash
sudo bash install.sh 9router.namadomain.com 19090
```

## Yang dilakukan script (sesuai urutan)

1. **Minta domain** — mis. `9router.namadomain.com` (atau dari argumen). Dicek apakah DNS-nya
   sudah mengarah ke IP VPS ini; kalau belum hanya peringatan, install tetap jalan.
2. **Minta port backend** (default `19090`) — port lokal di VPS yang akan menerima tunnel SSH
   dari server 9Router.
3. **Cek nginx** — install kalau belum ada, dilewati kalau sudah ada.
4. **Buat user SSH khusus `tunnel9r`** — tanpa shell (`/usr/sbin/nologin`), login hanya pakai
   key, dan key-nya dikunci dengan `restrict,port-forwarding` (tidak bisa eksekusi perintah
   apa pun, hanya boleh port-forwarding). Blok `Match User` ditambahkan di akhir `sshd_config`
   (backup dibuat otomatis).
5. **Generate nginx reverse proxy** — `domain -> 127.0.0.1:port` (dengan header websocket).
6. **Generate SSL** — certbot + Let's Encrypt otomatis untuk domain tersebut.

## Setelah install

Kirim ke asisten:

- IP publik VPS
- User tunnel: `tunnel9r`

Asisten menyambungkan SSH reverse tunnel dari server 9Router, lalu verifikasi
`https://<domain>/login`.

## Keamanan / dampak ke VPS

- Service lain **tidak disentuh**: tidak ada perubahan pada port 22/80/443 yang sudah dipakai,
  tidak ada perubahan pada site nginx yang sudah ada. Script hanya *menambah*.
- User `tunnel9r` tidak punya password, tidak punya shell, dan key-nya tidak bisa dipakai
  untuk menjalankan perintah — hanya untuk membuka tunnel port-forwarding.

## Uninstall

```bash
sudo userdel -r tunnel9r
sudo rm /etc/nginx/sites-enabled/9router.conf   # atau /etc/nginx/conf.d/9router.conf
sudo certbot delete --cert-name <domain-kamu>
sudo systemctl reload nginx sshd
```

## Lisensi

MIT — lihat [LICENSE](LICENSE).
