# Server deployment

The server is one Node.js process (API + website on one port) with SQLite and plain files. It runs on any
Linux server or Mac with Node.js 20+ (tested with Node 24). Docker is optional.

## Plain Node.js

```bash
cd server
npm ci
npm run init-env        # creates .env with random DEVICE_API_KEY / ADMIN_PASSWORD
$EDITOR .env            # set PUBLIC_BASE_URL, optional SMTP_*, PHOTOS_DIR …
npm run build
npm start               # node dist/index.js
```

`npm ci` uses prebuilt binaries for `sharp` and `better-sqlite3` (macOS and Linux x64/arm64, glibc and musl);
no compiler is needed.

### systemd

`server/deploy/photobooth.service` contains a hardened unit and install steps. Summary:

```bash
sudo useradd --system --home /opt/photobooth --shell /usr/sbin/nologin photobooth
sudo git clone <this repo> /opt/photobooth && sudo chown -R photobooth: /opt/photobooth
cd /opt/photobooth/server && sudo -u photobooth npm ci && sudo -u photobooth npm run build
sudo -u photobooth cp .env.example .env && sudo -u photobooth npm run init-env   # or edit by hand
sudo cp deploy/photobooth.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now photobooth
journalctl -u photobooth -f
```

If `PHOTOS_DIR` is outside `/opt/photobooth/server/data`, add it to `ReadWritePaths=` in the unit. The unit
also allows writing `/opt/photobooth/designs`, which *Admin ▸ Themes* needs.
`sudo systemctl reload photobooth` reloads designs without a restart.

## Docker (optional)

```bash
cd server && npm run init-env && cd ..     # or: cp server/.env.example server/.env and edit
docker compose up -d --build
docker compose logs -f
```

* Data (SQLite + photos) lives in the `photobooth-data` volume at `/data`.
* `./designs` is bind-mounted (writable, for *Admin ▸ Themes*); run `sudo chown -R 1000 designs` once so the
  container user can write to it. Design edits never need a rebuild.
* To keep photos on another disk, uncomment the `PHOTOS_DIR` lines in `docker-compose.yml`.
* Without Compose: `docker build -f server/Dockerfile -t photobooth-server .` from the repository root, then
  `docker run -d -p 8080:8080 --env-file server/.env -e DATA_DIR=/data -v pbdata:/data photobooth-server`.
* Run the CLI inside the container: `docker compose exec photobooth node dist/cli/admin.js events`.

The Dockerfile installs DejaVu and Liberation fonts for design text. (The Docker setup was written but not
built in this environment because Docker was not installed; please run `docker compose build` once.)

## Public access: Cloudflare Tunnel or a reverse proxy

Guests open links on their phones, so the gallery must be reachable from the internet. Set:

```env
PUBLIC_BASE_URL=https://photos.example.com   # used in QR codes, emails, gallery links
TRUST_PROXY=1                                # number of proxies in front of the server
```

The booth itself can upload either through the public URL or directly over the LAN (e.g.
`http://192.168.1.20:8080`) — the QR code always uses `PUBLIC_BASE_URL`, which the app reads from `/api/config`.

**Cloudflare Tunnel** (no open ports, free): see `server/deploy/cloudflared-config.example.yml`.

```bash
cloudflared tunnel login
cloudflared tunnel create photobooth
cloudflared tunnel route dns photobooth photos.example.com
cloudflared tunnel run photobooth     # or install it as a service: sudo cloudflared service install
```

Cloudflare's free plan limits request bodies to 100 MB, which is well above S5II JPEGs (~10–13 MB).

**Caddy / nginx**: `server/deploy/Caddyfile.example`. For nginx, proxy to `127.0.0.1:8080`, set
`client_max_body_size 60m;`, `proxy_request_buffering off;` and forward `X-Forwarded-For` / `X-Forwarded-Proto`.

## Event-day checklist

1. `curl https://photos.example.com/api/health` returns `{"ok":true,...}`.
2. In the booth app: Operator settings ▸ Server ▸ *Test connection* shows "API key accepted".
3. Take one test session and open its QR code on a phone over mobile data (not the event Wi-Fi).
4. If email is used: enter your own address once and check spam folders; set SPF/DKIM for `SMTP_FROM_EMAIL`.
5. Decide whether the event gallery should be public, password-protected or off (Admin page).

## Backups

Online backup (safe while the server is running and uploads continue):

```bash
cd server
npm run backup -- /mnt/backup             # production build: node dist/cli/backup.js /mnt/backup
```

It writes `/mnt/backup/photobooth-<timestamp>/photobooth.sqlite` (consistent copy via SQLite's backup API)
and `photos/` (a copy of `PHOTOS_DIR`). The database is copied first, so every photo it references is included.
Originals are write-once, so incremental tools work well too:

```bash
rsync -a --exclude .tmp "$PHOTOS_DIR"/ backup-host:/backups/photobooth-photos/
```

The iPad/iPhone also keeps every photo locally until the server has verified it (and longer, depending on the
retention setting); photos are visible in Files ▸ On My iPad ▸ Lumix Booth ▸ Sessions.

### Restore

```bash
sudo systemctl stop photobooth            # or: docker compose stop
cp /mnt/backup/photobooth-<ts>/photobooth.sqlite "$DATA_DIR"/photobooth.sqlite
rm -f "$DATA_DIR"/photobooth.sqlite-wal "$DATA_DIR"/photobooth.sqlite-shm
rsync -a /mnt/backup/photobooth-<ts>/photos/ "$PHOTOS_DIR"/
sudo systemctl start photobooth
```

Generated strips and thumbnails are caches and are recreated on demand if missing.

## Operations

```bash
npm run cli -- events                                  # counts per event
npm run cli -- sessions summer-party uploading         # sessions still uploading
npm run cli -- gallery summer-party password s3cret    # event gallery: disabled | public | password
npm run cli -- delete-session <sessionId>
npm run cli -- retry-emails
npm run cli -- designs                                 # installed designs and validation problems
```
(Production: `node dist/cli/admin.js …`.) Logs never contain credentials or guest email addresses; session IDs
are shortened to 6 characters.
