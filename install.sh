#!/usr/bin/env bash
#
# 9Router VPS Installer
# =====================
# Menjadikan VPS Ubuntu sebagai pintu publik yang STABIL untuk 9Router
# (menggantikan tunnel gratisan yang domainnya ganti-ganti).
#
# Cara install (copy-paste di VPS Ubuntu):
#   curl -fsSL https://raw.githubusercontent.com/zal-m10/9router-vps/main/install.sh -o install.sh \
#     && sudo bash install.sh
#
# Mode non-interaktif:
#   sudo bash install.sh 9router.namadomain.com 19090
#
# Yang dilakukan script, sesuai urutan:
#   1. Minta domain (atau dari argumen)
#   2. Minta port backend (default 19090)
#   3. Cek nginx -> install kalau belum ada (tidak disentuh kalau sudah ada)
#   4. Buat user SSH khusus tunnel (tanpa shell, key-only, hanya port-forwarding)
#   5. Generate nginx reverse proxy: domain -> 127.0.0.1:port
#   6. Generate SSL Let's Encrypt untuk domain (certbot)
#
# Service lain di VPS TIDAK disentuh: port 22/80/443 yang sudah dipakai tetap
# milik konfigurasi yang sudah ada. Script hanya MENAMBAH.
#
set -euo pipefail

# ---------- tampilan ----------
C_RESET='\033[0m'; C_BOLD='\033[1m'
C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_CYAN='\033[36m'
info() { echo -e "${C_CYAN}==>${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN} OK ${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW} !! ${C_RESET} $*"; }
err()  { echo -e "${C_RED} XX ${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

ask() { # ask <var> <prompt> [default]
  local var="$1" prompt="$2" def="${3:-}" ans=""
  if [ -n "$def" ]; then
    read -r -p "$prompt [$def]: " ans || true
    ans="${ans:-$def}"
  else
    read -r -p "$prompt: " ans || true
  fi
  printf -v "$var" '%s' "$ans"
}

# ---------- wajib root ----------
[ "$(id -u)" -eq 0 ] || die "Jalankan sebagai root: sudo bash install.sh [domain] [port]"

echo -e "${C_BOLD}9Router VPS Installer${C_RESET}"
echo

# ---------- 1. domain ----------
DOMAIN="${1:-}"
if [ -z "$DOMAIN" ]; then
  [ -t 0 ] || die "Butuh terminal interaktif, atau pakai mode non-interaktif: sudo bash install.sh <domain> [port]"
  ask DOMAIN "Masukkan domain untuk 9Router (contoh: 9router.namadomain.com)"
fi
[ -n "$DOMAIN" ] || die "Domain tidak boleh kosong."
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "Format domain tidak valid: $DOMAIN"

# ---------- 2. port backend ----------
PORT="${2:-}"
if [ -z "$PORT" ]; then
  if [ -t 0 ]; then
    ask PORT "Port lokal backend (tunnel 9Router akan diteruskan ke sini)" "19090"
  else
    PORT="19090"
  fi
fi
[[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] \
  || die "Port tidak valid: $PORT"
if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$PORT\$"; then
  die "Port $PORT sudah dipakai di VPS ini. Pilih port lain."
fi

echo
info "Domain : $DOMAIN"
info "Backend: 127.0.0.1:$PORT"
echo

# ---------- IP publik & cek DNS ----------
PUBIP="$(curl -s --max-time 10 https://api.ipify.org || true)"
[ -n "$PUBIP" ] || die "Tidak bisa mendeteksi IP publik VPS."
info "IP publik VPS: $PUBIP"
DNSIP="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
if [ -n "$DNSIP" ] && [ "$DNSIP" != "$PUBIP" ]; then
  warn "DNS $DOMAIN menunjuk ke $DNSIP, bukan IP VPS ini ($PUBIP)."
  warn "Buat A record: $DOMAIN -> $PUBIP, kalau tidak sertifikat SSL akan gagal."
  LANJUT="y"; [ -t 0 ] && ask LANJUT "Lanjut anyway? (y/n)" "y"
  [[ "$LANJUT" =~ ^[Yy] ]] || die "Dibatalkan."
elif [ -z "$DNSIP" ]; then
  warn "Domain $DOMAIN belum resolve ke IP mana pun."
  warn "Buat A record: $DOMAIN -> $PUBIP sebelum/sesudah install, lalu (re)run certbot."
fi

# ---------- 3. nginx ----------
if command -v nginx >/dev/null 2>&1; then
  ok "nginx sudah terinstall ($(nginx -v 2>&1 | cut -d/ -f2)), tidak diinstall ulang."
else
  info "nginx belum ada -> install ..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx curl
  ok "nginx terinstall."
fi
systemctl enable --now nginx >/dev/null 2>&1 || true

# ---------- 4. user SSH khusus tunnel ----------
TUNNEL_USER="tunnel9r"
# Public key milik server 9Router (boleh disebar, ini BUKAN password)
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMT2WA0k+jEP7Fk1LQiD+0NVCjPudNsSZfpQNBFlvmzr 9router-tunnel'

# Deteksi nama service SSH (Ubuntu: ssh.service, RHEL/CentOS: sshd.service)
SSH_SVC="ssh"
if systemctl cat sshd.service >/dev/null 2>&1; then SSH_SVC="sshd"; fi

info "Siapkan user SSH khusus tunnel: $TUNNEL_USER ..."
if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
  useradd -m -s /usr/sbin/nologin "$TUNNEL_USER"
fi
mkdir -p "/home/$TUNNEL_USER/.ssh"
# restrict = matikan semua (pty, shell, agent, X11); port-forwarding = nyalakan lagi
echo "restrict,port-forwarding $PUBKEY" > "/home/$TUNNEL_USER/.ssh/authorized_keys"
chmod 700 "/home/$TUNNEL_USER/.ssh"
chmod 600 "/home/$TUNNEL_USER/.ssh/authorized_keys"
chown -R "$TUNNEL_USER:$TUNNEL_USER" "/home/$TUNNEL_USER/.ssh"
if ! grep -q "Match User $TUNNEL_USER" /etc/ssh/sshd_config; then
  cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
  cat >> /etc/ssh/sshd_config <<EOF

# 9Router tunnel user (9router-vps/install.sh) - blok Match harus di akhir file
Match User $TUNNEL_USER
    AllowTcpForwarding yes
    X11Forwarding no
    AllowAgentForwarding no
    PermitTunnel no
EOF
fi
sshd -t || die "sshd_config tidak valid, periksa manual."
if systemctl reload "$SSH_SVC"; then
  ok "user $TUNNEL_USER siap (tanpa shell, key-only, hanya port-forwarding)."
else
  die "Gagal reload $SSH_SVC. Jalankan manual: sudo systemctl reload $SSH_SVC"
fi

# ---------- 5. generate nginx reverse proxy ----------
info "Generate nginx reverse proxy untuk $DOMAIN ..."
NGINX_NAME="9router.conf"
if [ -d /etc/nginx/sites-enabled ]; then
  DEST="/etc/nginx/sites-enabled/$NGINX_NAME"
elif [ -d /etc/nginx/conf.d ]; then
  DEST="/etc/nginx/conf.d/$NGINX_NAME"
else
  die "Tidak ketemu /etc/nginx/sites-enabled maupun conf.d"
fi

cat > "$DEST" <<EOF
# 9Router public endpoint (9router-vps/install.sh)
# Meneruskan $DOMAIN -> tunnel SSH 9Router di 127.0.0.1:$PORT (VPS ini)
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
EOF
nginx -t || die "Konfigurasi nginx tidak valid."
systemctl reload nginx
ok "nginx config OK: $DEST"

# ---------- firewall ringan (kalau ufw aktif) ----------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 80/tcp >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
  ok "ufw: port 80 & 443 dibuka."
fi

# ---------- 6. generate SSL ----------
info "Generate sertifikat SSL (Let's Encrypt) ..."
if ! command -v certbot >/dev/null 2>&1; then
  info "certbot belum ada -> install ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot python3-certbot-nginx
fi
if certbot --nginx --non-interactive --agree-tos --register-unsafely-without-email \
    -d "$DOMAIN" --redirect; then
  ok "SSL aktif: https://$DOMAIN"
else
  warn "certbot gagal (biasanya karena DNS $DOMAIN belum mengarah ke $PUBIP)."
  warn "Setelah A record aktif, jalankan manual:  sudo certbot --nginx -d $DOMAIN"
fi

# ---------- selesai ----------
echo
echo -e "${C_GREEN}${C_BOLD}SELESAI.${C_RESET}"
echo "  URL publik (stabil) : https://$DOMAIN"
echo "  Backend tunnel      : 127.0.0.1:$PORT (menunggu koneksi SSH dari server 9Router)"
echo
echo "  Kirim ke asistenmu:"
echo "    - IP publik VPS : $PUBIP"
echo "    - User tunnel   : $TUNNEL_USER"
echo
echo "  Setelah tunnel tersambung, verifikasi: https://$DOMAIN/login"
