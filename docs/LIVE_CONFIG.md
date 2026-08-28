# LIVE_CONFIG.md

Local documentation of the **deployed/running** stremio-docker configuration on this host.
This branch (`tailscale-https-support`) is the live, in-use config powering the running container
`stremio-docker`. Keep this branch stable; do not sanitise it against upstream.

The following notes compare the live files against the **current upstream default**
(`tsaridas/stremio-docker` @ `main`) and explain the reason behind each deviation.

---

## 1. compose.yaml

Upstream default:

```yaml
services:
  stremio:
    image: tsaridas/stremio-docker:latest
    restart: unless-stopped
    environment:
      NO_CORS: 1
      AUTO_SERVER_URL: 1
      #IPADDRESS: 192.168.1.10 # Setup your ip address here
    ports:
      - "8080:8080"
    volumes:
      - "./stremio-data:/root/.stremio-server"
```

Live version (this branch):

```yaml
services:
  stremio:
    container_name: stremio-docker
    image: tsaridas/stremio-docker:latest
    restart: unless-stopped
    environment:
      NO_CORS: 1
      AUTO_SERVER_URL: 1
      DOMAIN: "YOUR_HOST.example-tailnet.ts.net:8080"
      CERT_FILE: "stremio-cert.pem"
    ports:
      - "100.64.0.0:8080:8080"
    volumes:
      - "./stremio-data:/root/.stremio-server"
      - "./nginx/https.conf:/etc/nginx/https.conf:ro"
      - "./nginx/nginx.conf:/etc/nginx/nginx.conf:ro"
      - "./restart_if_idle.sh:/srv/stremio-server/restart_if_idle.sh"
    devices:
      - "/dev/dri:/dev/dri"
```

### Deviations from upstream

| Item | Upstream | Live | Reason |
|---|---|---|---|
| `container_name` | (auto) | `stremio-docker` | Stable container name for scripts/healthchecks. |
| `DOMAIN` | unset | `YOUR_HOST.example-tailnet.ts.net:8080` | Uses the host's **Tailscale Tailnet FQDN** certificate (see §4). The `:8080` suffix is a deliberate quirk — see below. |
| `CERT_FILE` | unset | `stremio-cert.pem` | Signals the entrypoint to load a user-supplied cert instead of fetching the provisioned `stremio.rocks` one. |
| `ports` | `8080:8080` (all IFs) | `100.64.0.0:8080:8080` | Binds only to the **Tailscale interface IP** (`100.64.0.0`), exposing the service exclusively on the tailnet, not the LAN/WAN. |
| https.conf volume | none | `:ro` mount | Overrides the in-image HTTPS vhost with the live tweaked version (see §2). |
| nginx.conf volume | none | `:ro` mount | Overrides the in-image main nginx config with the real-IP tweak (see §3). |
| restart script volume | none | `:ro` mount | Mounts the live `restart_if_idle.sh` (memory-guard healthcheck). |
| `devices` | none | `/dev/dri:/dev/dri` | Exposes the GPU for VA-API hardware transcoding. |

### Why the `:8080` suffix in `DOMAIN` (empirically-derived hack)

The entrypoint (`stremio-web-service-run.sh`) runs, for the `CERT_FILE` path:

```sh
node certificate.js --action load --pem-path /srv/stremio-server/certificates.pem \
    --domain "${DOMAIN}" --json-path "…/httpsCert.json"
```

`certificate.js` writes `{ domain, key, cert, … }` into `httpsCert.json` **verbatim** — the value
you set in `DOMAIN` (including any `:PORT`) is stored as the `domain` field. The running
`httpsCert.json` on this host confirms:

```json
"domain": "YOUR_HOST.example-tailnet.ts.net:8080"
```

The stremio server bundles this `domain` into the streaming configuration it advertises to
clients (server.js: `domain: cert.domain`). Because nginx terminates HTTPS on port **8080**
(see §2), a client connecting to the streaming server actually reaches it at
`https://YOUR_HOST.example-tailnet.ts.net:8080/`. Storing the domain **with the port** makes the URL
the server reports to Stremio clients match the URL they physically connect to, which keeps
certificate/host validation and server-URL autodetection consistent.

> Note: this was arrived at empirically. It is treated as a "flukey but working" hack that
> combines (a) making the reported server domain equal the real client-visible URL, and (b)
> aligning with nginx's actual `listen … 8080` directive. If upstream ever changes how `DOMAIN`
> is consumed, this pairing may need re-verifying.

---

## 2. nginx/https.conf

The live `nginx/https.conf` differs from upstream in the `location /` and trailing sections:
upstream ends with `try_files $uri $uri/ /index.html;`, while the live config proxies
unknown paths to the backend streaming server.

```diff
     location / {
         include /etc/nginx/auth.conf;
         root /srv/stremio-server/build;
         index index.html index.htm;
-        try_files $uri $uri/ /index.html;
+        try_files $uri $uri/ @backend;

         location ~* \.(jpg|jpeg|png|gif|ico|css|js|woff2|env)$ {
             expires 7d;
             add_header Cache-Control "public, no-transform";
         }
     }
+
+    # Fallback to backend if file not found (for streaming server)
+    location @backend {
+        include /etc/nginx/auth.conf;
+        proxy_pass http://backend;
+    }
```

### Why

This is the core "streaming server at the same URL" tweak. Upstream serves the web UI and
proxies only the known stremio API/composite routes to the backend (`127.0.0.1:11470`). Any
request that is not a known route and is not a static file falls through to `/index.html`.

For external Stremio clients we need the **streaming server** (the node process bound to
`11470`) reachable at the **same host:port** as the web player. Adding the `@backend` named
location as the final fallback makes nginx forward unrecognised paths (i.e. streaming-server
traffic such as transcoded segment requests) to `http://backend` rather than returning the SPA
`index.html`. This lets the web UI and the streaming server coexist behind one TLS listener.

Also carries the port-suffixed-domain interaction from §1: clients hit `:8080`, and this
`@backend` fallback forwards the underlying streaming requests to the backend on `11470`.

---

## 3. nginx/nginx.conf

The live `nginx/nginx.conf` adds a real-IP block and a minor comment edge-case fix:

```diff
 http {
+    # Trust Docker networks for real IP forwarding
+    set_real_ip_from 172.16.0.0/12;
+    set_real_ip_from 10.0.0.0/8;
+    set_real_ip_from 192.168.0.0/16;
+    real_ip_header X-Forwarded-For;
+    real_ip_recursive on;
+    ...
 }
```

### Why

With the `@backend` fallback in §2 proxying arbitrary request paths, the backend stremio server
sees `X-Forwarded-For` populated by nginx. The `set_real_ip_from` / `real_ip_header` /
`real_ip_recursive` directives tell nginx to trust the Docker bridge/proxied networks and use
the **right-most untrusted** address in `X-Forwarded-For` as the real client IP. Without this,
the backend would see nginx's container IP (or a spoofable header) instead of the actual client,
which breaks IP-based features and logging.

The trusted CIDRs (`172.16.0.0/12`, `10.0.0.0/8`, `192.168.0.0/16`) cover the private ranges a
Docker/Tailscale deployment typically runs on.

---

## 4. Tailscale FQDN certificate workflow (SEC1 EC → PKCS#8)

The HTTPS certificate in use is the **host machine's Tailscale Tailnet FQDN** certificate:
`YOUR_HOST.example-tailnet.ts.net`. This is *not* the `*.stremio.rocks` certificate the project
normally provisions.

**Why the key conversion is required:**

- `tailscale cert` issues the key in **SEC1 EC** form (`-----BEGIN EC PRIVATE KEY-----`).
- The container's `certificate.js` `loadCertificate()` extracts the private key with the regex:

  ```js
  /-----BEGIN (?:RSA )?PRIVATE KEY-----[\s\S]+?-----END (?:RSA )?PRIVATE KEY-----/
  ```

  This matches **PKCS#8** (`BEGIN PRIVATE KEY`) or **legacy RSA** (`BEGIN RSA PRIVATE KEY`) — it
  does **not** match `BEGIN EC PRIVATE KEY`. If the SEC1 key is passed in unchanged,
  `loadCertificate()` throws `No private key found …` and the cert setup fails.

- Therefore the SEC1 EC key must be **converted to PKCS#8** (`-----BEGIN PRIVATE KEY-----`) before
  the combined PEM is placed in `stremio-data/stremio-cert.pem`.

### The conversion steps (as used on this host)

```bash
cd REPO_DIR

# 1. Force-convert the SEC1 EC key into a standard PKCS#8 private key
sudo openssl pkcs8 -topk8 -nocrypt \
    -in  /path/to/certs/YOUR_HOST.example-tailnet.ts.net.key \
    -out stremio-data/pkcs8_ec.key

# 2. Combine the certificate chain + new PKCS#8 key into the PEM the container expects
sudo sh -c "cat /path/to/certs/YOUR_HOST.example-tailnet.ts.net.crt \
    stremio-data/pkcs8_ec.key > stremio-data/stremio-cert.pem"

# 3. Remove the temporary PKCS#8 key file
sudo rm -f stremio-data/pkcs8_ec.key

# 4. Correct permissions and ownership so the container can read it
sudo chmod 640 stremio-data/stremio-cert.pem
sudo chown $(id -u):$(id -g) stremio-data/stremio-cert.pem
```

### Notes

- The combined `stremio-cert.pem` contains the full certificate chain **plus** the PKCS#8 private
  key. `certificate.js` splits them back out at load time.
- The file is under `stremio-data/`, which is git-ignored — never commit it (it contains the
  private key).
- When the Tailscale cert is renewed, the `crt`/`key` change and steps 1–4 must be re-run.
- Uses `sudo` because the host Tailscale cert store is root-owned.

---

## Reference: three-file deviation summary

| File | Upstream | Live | Purpose |
|---|---|---|---|
| `compose.yaml` | default ports/volumes | Tailscale bind, cert env, config mounts, GPU | Run HTTPS on the tailnet with the FQDN cert + GPU |
| `nginx/https.conf` | SPA-only fallback | adds `@backend` streaming fallback | Web UI + streaming server behind one TLS port |
| `nginx/nginx.conf` | none | real-IP trust from Docker/Tailscale CIDRs | Correct client IPs behind proxy |
