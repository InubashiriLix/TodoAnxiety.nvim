# TodoAnxiety sync server

A single-user, multi-device sync service. SQLite is compiled into the binary;
images are stored in the data directory. No Docker, PostgreSQL or object-store
service is needed. DeepSeek requests go directly from Neovim to DeepSeek.

## Build

```sh
cargo test --locked
cargo build --release --locked
```

For a static Linux binary, install a Rust musl target and its C cross compiler:

```sh
rustup target add x86_64-unknown-linux-musl
cargo build --locked --release --target x86_64-unknown-linux-musl
file target/x86_64-unknown-linux-musl/release/todoanxiety-sync
readelf -l target/x86_64-unknown-linux-musl/release/todoanxiety-sync
readelf -d target/x86_64-unknown-linux-musl/release/todoanxiety-sync
```

The static artifact must have no `INTERP` or `NEEDED` entries. The repository's
server workflow builds x86_64 and aarch64 musl artifacts and tests this property.
It uploads build artifacts; it does not publish a release automatically.

## Run without systemd

```sh
./todoanxiety-sync init --data-dir ./data
./todoanxiety-sync token create laptop --data-dir ./data
./todoanxiety-sync serve --data-dir ./data --bind 127.0.0.1:8787
```

Token creation prints the token once. Save it in each device's local environment
as `TODO_SYNC_TOKEN`, using a separate token per device. Never commit it.
To revoke a token, use `token revoke --token-file /private/device.token --data-dir ./data`.
The secret is read from the file, never from a command argument.

## Install with systemd

```sh
sudo install -m 0755 todoanxiety-sync /usr/local/bin/todoanxiety-sync
sudo install -m 0644 deploy/todoanxiety-sync.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now todoanxiety-sync
sudo systemd-run --wait --pipe --collect --property=DynamicUser=yes --property=User=todoanxiety-sync --property=StateDirectory=todoanxiety-sync \
  /usr/local/bin/todoanxiety-sync token create laptop --data-dir /var/lib/todoanxiety-sync
```

The unit uses a dynamic user and `StateDirectory`, so systemd creates and owns
the persistent directory. Mint/revoke tokens while the service is running using
that same dynamic user, or use `systemctl stop` and an administrator to manage
files with appropriate ownership. `journalctl -u todoanxiety-sync` shows startup
and process errors. The database stores token hashes, not plaintext tokens.

The default listener is loopback. For a reverse proxy, for example Caddy:

```caddyfile
sync.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

Or supply `--tls-cert chain.pem --tls-key private.pem` for native rustls HTTPS.
For direct private-network access change `TODOANXIETY_BIND` with a systemd
service override. The Neovim client requires `allow_http=true` for plaintext
HTTP. HTTP does not encrypt tasks or bearer tokens. A custom CA can be configured
with `sync.ca_file`; disabling certificate verification is a separate opt-in.

## Back up and restore

```sh
./todoanxiety-sync backup --data-dir ./data --out ./backup-2026-10-15
```

This creates `sync.sqlite3` and copies immutable blobs, excluding staging files.
There is no automatic blob garbage collection. To restore, stop the service,
restore both the database and `blobs/` into its data directory, then restart it.
A backup must not be inside the live blob directory.

## Protocol and limits

All data routes require `Authorization: Bearer ...`; `/v1/status` is a public
version/health probe. Protocol version is 2. The URL prefix remains `/v1` for route compatibility; v1 clients must upgrade before importing v2 memory records.

- `POST /v1/push`: operation UUID, changes with `kind`, `key`, `base_version`,
  `value`, and attachment hashes. Entire operation commits or conflicts (409).
- `GET /v1/pull?after=N`: complete operations and the last returned cursor.
- `PUT/GET /v1/blobs/{sha256}`: authenticated, hash-verified images, up to 10 MiB.
- `POST/DELETE /v1/leases/{session}`: exclusive generation lease. Renewal requires
  the current owner and lease token; owner alone cannot renew or reacquire it.

JSON pushes are limited to 4 MiB and 1000 changes. A repeated operation ID with
identical bytes is idempotent; different bytes conflict. The plugin uses stable
JSON encoding for retries. The client retains offline work and exposes conflicts
through `:Todo sync conflicts` rather than silently overwriting either version.

## Offline deployment to `oracle-web-server`

Build and test the static artifact **on the local machine**. Inspect the remote
architecture with `oracle-run uname -m`, then select the matching artifact. Do
not run a package manager, clone a repository, download an artifact, or build
from network dependencies on the remote host.

For an x86_64 host, from `server/`:

```sh
sha256sum target/x86_64-unknown-linux-musl/release/todoanxiety-sync
oracle-upload target/x86_64-unknown-linux-musl/release/todoanxiety-sync /home/ubuntu/todoanxiety-sync
oracle-upload deploy/todoanxiety-sync.service /home/ubuntu/todoanxiety-sync.service
oracle-run sha256sum /home/ubuntu/todoanxiety-sync
oracle-run sudo -n install -m 0755 /home/ubuntu/todoanxiety-sync /usr/local/bin/todoanxiety-sync
oracle-run sudo -n install -m 0644 /home/ubuntu/todoanxiety-sync.service /etc/systemd/system/todoanxiety-sync.service
oracle-run sudo -n systemctl daemon-reload
oracle-run sudo -n systemctl enable --now todoanxiety-sync
oracle-run curl --fail --silent --show-error http://127.0.0.1:8787/v1/status
```

Inspect and back up any existing installation before replacing it. Keep the
listener on loopback and reuse the host's existing TLS reverse proxy.
[deploy/nginx-limits.conf](deploy/nginx-limits.conf) defines rate/concurrency zones
in the existing `http {}` block.
[deploy/nginx-location.conf](deploy/nginx-location.conf) adds `/todo-sync/` to an
existing HTTPS server block without changing the application at `/`.
`proxy_pass` ends in `/` so the prefix is removed before forwarding. Set the
client URL to `https://YOUR_HOST/todo-sync`. The sample does not require Nginx's
rewrite module, which is absent in some minimal builds.

Back up the live Nginx configuration, test with the host's installed `nginx -t`,
and reload its existing service only after validation succeeds. Do not install
another proxy or fetch a certificate on the remote machine as part of this
procedure. Verify `/v1/status`, an unauthenticated pull (401), and an authenticated
client sync over HTTPS from the local machine. The existing application should
continue to respond at `/`.

Mint a separate bearer token for each device with the dynamic user shown above.
Redirect its output into a private file (umask 077), transfer it with
`oracle-download`, enforce mode 0600 locally, and remove the remote plaintext
copy after successful transfer. Never put a bearer token in command arguments,
a repository, logs, or documentation. The server stores only its hash.

To roll back proxy routing, restore the saved configuration, validate it and
reload the existing Nginx service. Stop/disable only `todoanxiety-sync` if removing
the new service; retain its data directory and backups. Confirm existing routes
still work. Certificate renewal remains the responsibility of the host's
existing TLS setup.

## Security and Lua configuration

Data routes require bearer authentication before reading the request body; only
`/v1/status` is public and returns the protocol version. Tokens are issued only
by the administrator CLI, stored as SHA-256 hashes, and checked on every request.
This is a single-user service: device tokens grant access to the same dataset.
There is no end-to-end encryption of task content in the server database.

The Nginx templates add per-IP request rates (10/s, burst queue 40), per-IP and
global concurrency limits (8/32), timeouts, body limits and no-store responses.
Install both templates in the documented scopes, validate before reload, and
adjust limits for the host. They do not provide protection against bandwidth
saturation. The systemd unit limits memory, tasks and file descriptors.

Clients can configure a token file, string, callback or environment variable in
Lua; AI credentials have equivalent options. No settings UI is required.
See [security details](../doc/security.md) and
[the complete Lua configuration example](../doc/configuration.md).
