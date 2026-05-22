# Roadmap: cvcpkg 2.0 — production registry with trust & identity

Status: **Planning** (no implementation started).
Author: roadmap drafted 2026-05-22.
Target: libcvc-deps v2.0.0 (with possible 1.x releases working up to it).

---

## 1. Motivation

cvcpkg 1.x proved the recipe-driven component model: 25 recipes, a
FastAPI server, storage backends, per-component bundles, and a
lockfile-based install flow.  However, the entire stack is still
GitHub-centric — catalogs live on GitHub Pages, archives attach to
GitHub Releases, and there is no public registration path for
third-party publishers.

v2.0 makes the **cvcpkg daemon the authoritative registry** for
package catalogs, decoupled from any single hosting provider.  It adds
a proper database, multi-backend package mirroring, public publisher
registration with admin review, cryptographic identity for publishers,
and supply-chain protections for package names.

### Goals

| # | Goal |
|---|------|
| G1 | The daemon is the source of truth for the catalog; GitHub is one mirror among many. |
| G2 | Packages can be fetched from any configured backend (GitHub Releases, S3, SFTP, arbitrary HTTPS, local disk). The daemon tries each in order. |
| G3 | The public can request credentials to publish packages; admins review and approve. |
| G4 | Package names are reserved upon first publish and bound to a verified publisher identity. Admins can block or transfer name ownership. |
| G5 | Every published artifact is signed by the publisher's key; the daemon and clients verify signatures before accepting. |
| G6 | A public publisher directory lets anyone query who owns a package name and inspect their signing key. |
| G7 | The daemon uses a database (SQLite/MySQL/PostgreSQL via SQLModel) instead of YAML files. |

### Non-goals

- Replacing vcpkg, conan, or spack.  cvcpkg serves the CVC/libcvc
  ecosystem only.
- Running a CDN.  The daemon proxies or redirects to storage backends;
  it is not itself a high-throughput file server.
- Automatic trust.  Every new publisher goes through human review.

---

## 2. Architecture overview

```
                          ┌───────────────────────┐
  cvcpkg CLI ────────────►│   cvcpkg-server 2.0   │
  (install / publish)     │     (FastAPI)          │
                          │                        │
                          │  ┌─────────────────┐   │
                          │  │ SQLModel DB      │   │
                          │  │ (SQLite/PG/MySQL)│   │
                          │  └─────────────────┘   │
                          │                        │
                          │  ┌─────────────────┐   │
                          │  │ Backend Router   │   │
                          │  │  ├─ GitHub Rel.  │   │
                          │  │  ├─ S3           │   │
                          │  │  ├─ SFTP         │   │
                          │  │  ├─ HTTPS mirror │   │
                          │  │  └─ Local disk   │   │
                          │  └─────────────────┘   │
                          │                        │
                          │  ┌─────────────────┐   │
                          │  │ Signature Verify │   │
                          │  │ (Ed25519 / GPG)  │   │
                          │  └─────────────────┘   │
                          └───────────────────────┘
```

---

## 3. Database layer (SQLModel)

### 3.1. Why SQLModel

The 1.x server stores tokens, audit entries, and the package index in
YAML files.  This works for a single-node lab deployment but cannot
support:

- Concurrent writes from multiple uvicorn workers.
- Indexed queries (packages by name, platform, publisher).
- Transactional integrity (publish + audit in one commit).
- Horizontal scaling behind a load balancer.

[SQLModel](https://sqlmodel.tiangolo.com/) sits on top of SQLAlchemy
and Pydantic, so the existing Pydantic models migrate almost
verbatim.  The backend is selected by a single `DATABASE_URL`
environment variable:

| Backend    | DATABASE_URL example                     | Use case               |
|------------|------------------------------------------|------------------------|
| SQLite     | `sqlite:///var/lib/cvcpkg/cvcpkg.db`     | Single-node, dev, CI   |
| PostgreSQL | `postgresql://user:pw@db:5432/cvcpkg`    | Production multi-node  |
| MySQL      | `mysql://user:pw@db:3306/cvcpkg`         | Enterprise deployments |

### 3.2. Data model

```
Publisher
  id              UUID PK
  username        UNIQUE
  display_name
  email
  public_key      TEXT (PEM-encoded Ed25519 public key)
  key_fingerprint TEXT (SHA-256 of public key bytes)
  status          ENUM(pending, active, suspended, revoked)
  created_at
  updated_at
  reviewed_by     FK → Publisher.id  (admin who approved)
  review_note     TEXT

PackageName
  name            PK
  owner_id        FK → Publisher.id
  created_at
  status          ENUM(active, reserved, blocked)
  blocked_reason  TEXT
  blocked_by      FK → Publisher.id  (admin)

PackageRelease
  id              UUID PK
  name            FK → PackageName.name
  version         TEXT
  platform        TEXT
  arch            TEXT
  config          TEXT   (release | debug)
  link            TEXT   (shared | static)
  sha256          TEXT
  size_bytes      BIGINT
  signature       TEXT   (detached Ed25519 signature, base64)
  published_by    FK → Publisher.id
  published_at    DATETIME
  yanked          BOOL DEFAULT FALSE
  yanked_by       FK → Publisher.id
  yanked_at       DATETIME
  storage_uris    JSON   (list of backend URIs where the archive lives)
  UNIQUE(name, version, platform, arch, config, link)

Token
  id              UUID PK
  owner_id        FK → Publisher.id
  name            TEXT
  token_hash      TEXT
  role            ENUM(reader, publisher, admin)
  scopes          JSON   (list of package name patterns, e.g. ["my-lib", "my-*"])
  created_at
  expires_at
  revoked         BOOL DEFAULT FALSE
  revoked_by      FK → Publisher.id

AuditEntry
  id              BIGINT PK AUTO
  timestamp       DATETIME
  action          ENUM(...)
  actor_id        FK → Publisher.id
  target          TEXT
  detail          TEXT
  prev_hash       TEXT   (chained SHA-256 for tamper detection)

StorageBackend
  id              UUID PK
  scheme          TEXT (s3, sftp, https, gh-release, local)
  uri_prefix      TEXT
  priority        INT  (lower = tried first)
  enabled         BOOL DEFAULT TRUE
  credentials_ref TEXT (vault path, env var name, or inline for dev)
  health_check_at DATETIME
  healthy         BOOL DEFAULT TRUE
```

### 3.3. Migration from 1.x

- A one-shot CLI command `cvcpkg-server migrate-from-v1 <state_dir>`
  reads the existing YAML files (tokens.yaml, audit.yaml, index.yaml)
  and imports them into the database.
- The v2 server refuses to start if it detects YAML-era files without
  a migration marker, printing clear instructions.

---

## 4. Multi-backend storage & mirroring

### 4.1. Backend router

The daemon maintains an ordered list of `StorageBackend` entries (from
the database).  On **download**, the router:

1. Queries `PackageRelease.storage_uris` for known locations.
2. Tries each URI in backend-priority order.
3. Returns a redirect (HTTP 302) or streams the bytes, depending on
   whether the backend supports direct client access.
4. If all fail, returns 502 with diagnostics.

On **publish**, the daemon:

1. Accepts the upload into a temporary staging area.
2. Verifies the publisher's Ed25519 signature (see §6).
3. Writes the archive to the **primary** backend.
4. Enqueues async replication to secondary backends (best-effort;
   failure is logged but does not block the publish response).
5. Records all successful URIs in `PackageRelease.storage_uris`.

### 4.2. Health checks

A background task (configurable interval, default 5 min) pings each
backend's `head()` on a sentinel object.  Unhealthy backends are
deprioritized until they recover.

### 4.3. Client-side fallback

The `cvcpkg install` client also has its own backend list (from
`~/.config/cvcpkg/config.yaml` mirrors).  If the daemon is
unreachable, the client can fall back to direct-from-mirror download
using the lockfile's `storage_uris` field.  This preserves offline /
air-gapped install capability.

---

## 5. Public publisher registration

### 5.1. Registration flow

```
User                           cvcpkg-server                   Admin
 │                                  │                            │
 │  POST /v2/publishers/register    │                            │
 │  { username, email, public_key } │                            │
 │ ────────────────────────────────►│                            │
 │                                  │  status = "pending"        │
 │  ◄─ 201 { id, status: pending } │                            │
 │                                  │                            │
 │                                  │  GET /v2/admin/publishers  │
 │                                  │◄───────────────────────────│
 │                                  │  ──► list of pending       │
 │                                  │                            │
 │                                  │  POST /v2/admin/publishers │
 │                                  │       /{id}/approve        │
 │                                  │◄───────────────────────────│
 │                                  │  status = "active"         │
 │                                  │                            │
 │  POST /v2/tokens                 │                            │
 │  (now allowed — identity active) │                            │
 │ ────────────────────────────────►│                            │
 │  ◄─ 201 { token: "cvctok_..." } │                            │
```

1. **Anyone** can call `POST /v2/publishers/register` with a username,
   email, and Ed25519 public key.  The server returns status `pending`.
2. An **admin** reviews the request via `GET /v2/admin/publishers?status=pending`.
   They can approve, reject (with reason), or request more info.
3. Once approved, the publisher can create tokens and publish packages.
4. Email verification (link or code) is optional but recommended;
   enforceability depends on deployment.  For CVC internal use, admin
   approval alone suffices.

### 5.2. Why admin review instead of fully automated?

- Supply-chain attack surface: automated signup lets an attacker
  claim names before legitimate publishers do.
- CVC is a small ecosystem; the review load is manageable.
- Admin review doubles as an introduction: new publishers get a human
  point of contact.
- We can relax to semi-automated (e.g. GitHub OAuth with org
  membership check) in a future minor release if the review queue
  becomes a bottleneck.

### 5.3. CLI registration helper

```bash
# Generate a keypair if the user doesn't have one:
cvcpkg identity init
# → writes ~/.config/cvcpkg/identity/ed25519.key (private)
# → writes ~/.config/cvcpkg/identity/ed25519.pub (public)

# Register with a server:
cvcpkg identity register --server https://pkg.cvc.example.org \
  --username alice --email alice@example.org
# → sends public key to server, prints "pending admin approval"

# Check status:
cvcpkg identity status --server https://pkg.cvc.example.org
```

---

## 6. Package name governance

### 6.1. Name reservation

The first time a publisher successfully publishes a package with a
given name, a `PackageName` row is created with `owner_id` pointing
to that publisher.  Subsequent publishes to the same name must come
from the same publisher (or an admin).

### 6.2. Admin controls

| Action | Endpoint | Who |
|--------|----------|-----|
| Block a name | `POST /v2/admin/names/{name}/block` | admin |
| Unblock a name | `POST /v2/admin/names/{name}/unblock` | admin |
| Transfer ownership | `POST /v2/admin/names/{name}/transfer` | admin |
| List all names | `GET /v2/admin/names` | admin |
| Revoke publisher | `POST /v2/admin/publishers/{id}/suspend` | admin |

### 6.3. Proactive name blocking

Before a release, admins can pre-reserve names for well-known
upstream projects (boost, hdf5, vtk, qt6, etc.) so that no one can
squat them.  The seed list is derived from `packaging/components.yaml`.

### 6.4. Name policy rules (enforced server-side)

- Names must match `^[a-z][a-z0-9_-]{0,63}$`.
- Names that are substrings or close Levenshtein-distance matches of
  a blocked name trigger a manual review flag (typo-squatting
  detection).
- The server logs every rejected publish attempt in the audit trail.

---

## 7. Cryptographic publisher identity

### 7.1. Key type

Ed25519 (via the `cryptography` package or `PyNaCl`).  Ed25519 is:

- Fast (sign + verify < 0.1 ms).
- Small keys (32 bytes public, 64 bytes private).
- Widely supported (OpenSSH, GPG, sigstore, TUF).
- No parameter choice risk (unlike RSA key sizes or EC curves).

### 7.2. Signing flow

```
Publisher (cvcpkg CLI)           cvcpkg-server
  │                                  │
  │  1. Build archive                │
  │  2. SHA-256 of archive bytes     │
  │  3. Ed25519 sign(sha256, privk)  │
  │                                  │
  │  POST /v2/publish                │
  │  { archive, signature, pubkey_fp}│
  │ ────────────────────────────────►│
  │                                  │  4. Look up publisher by fingerprint
  │                                  │  5. Verify signature against stored pubkey
  │                                  │  6. Verify SHA-256 matches uploaded bytes
  │                                  │  7. Check name ownership
  │                                  │  8. Store archive + signature
  │                                  │  9. Record in audit log
  │  ◄─ 201 { published }           │
```

### 7.3. Key rotation

- A publisher can register a **new** public key via
  `POST /v2/publishers/{id}/keys` (authenticated, requires current
  token).  The old key remains valid for verification of already-
  published artifacts but cannot sign new publishes after a
  configurable grace period (default: 30 days).
- Admins can force-rotate a publisher's key if compromise is
  suspected.

### 7.4. Client-side verification

On `cvcpkg install`, the client:

1. Fetches the package metadata (includes `signature` and
   `published_by` fingerprint).
2. Fetches the publisher's public key from the publisher directory.
3. Verifies the Ed25519 signature over the archive's SHA-256 digest.
4. If verification fails, the install is aborted with a clear error.
5. The `--trust-on-first-use` flag can be used to accept a publisher's
   key the first time and pin it for future installs (TOFU model,
   stored in `~/.config/cvcpkg/trusted_publishers.yaml`).

---

## 8. Publisher directory

### 8.1. Public endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /v2/publishers` | List all active publishers (paginated). |
| `GET /v2/publishers/{username}` | Publisher profile: display name, public key, fingerprint, packages owned. |
| `GET /v2/publishers/{username}/packages` | All packages published by this publisher. |
| `GET /v2/names/{name}` | Which publisher owns this package name + publishing history. |

### 8.2. Data exposed

- Username, display name (optional).
- Public key (PEM) and fingerprint.
- Account creation date.
- List of owned package names with latest version per platform.

What is **not** exposed:

- Email address (admin-only).
- Token details (never).
- Internal review notes (admin-only).

---

## 9. Admin revocation powers

### 9.1. Credential revocation

An admin can revoke a publisher's credentials at any time:

```
POST /v2/admin/publishers/{id}/suspend
{ "reason": "Compromised key — contacted publisher" }
```

This:
- Sets `Publisher.status = suspended`.
- Revokes all active tokens for that publisher.
- Marks all their packages as **yanked** (still downloadable for
  pinned lockfiles, but not resolved for new installs).
- Records the action in the audit log.

Re-enabling requires `POST /v2/admin/publishers/{id}/reinstate` +
a new public key upload by the publisher.

### 9.2. Name revocation

An admin can strip a publisher's ownership of a specific package name
without suspending their entire account:

```
POST /v2/admin/names/{name}/block
{ "reason": "Name squatting — reserving for upstream maintainer" }
```

This blocks new publishes to that name by anyone until the admin
explicitly transfers it or unblocks it.

### 9.3. Artifact revocation

Individual releases can be deleted (hard) or yanked (soft):

- **Yank**: `POST /v2/packages/{name}/{version}/yank` — existing
  lockfiles pointing to the exact SHA still resolve, but new
  `cvcpkg install` will not select the yanked version.
- **Delete**: `DELETE /v2/packages/{name}/{version}` — archive
  removed from all backends.  Lockfiles referencing it will fail.
  Admin-only.

---

## 10. Phased delivery plan

### Phase 0: prerequisite 1.x releases (v1.3.x – v1.4.x)

Work that can ship under the 1.x line without breaking changes:

- [ ] Harden the existing storage backend interface with retry logic
      and connection pooling.
- [ ] Add `cvcpkg identity init` and local Ed25519 keypair management
      (no server integration yet — just the key generation + storage).
- [ ] Add `signature` field to manifest schema (optional, ignored
      by 1.x server).
- [ ] Prototype SQLModel models alongside existing YAML store (dual-
      write for testing, YAML remains authoritative).
- [ ] Expand test coverage to ≥80%.

### Phase 1: database migration (v2.0.0-alpha)

- [ ] Replace YAML stores with SQLModel backend.
- [ ] `cvcpkg-server migrate-from-v1` CLI command.
- [ ] Alembic migration scaffolding for future schema changes.
- [ ] All existing 1.x server tests pass against SQLite backend.
- [ ] CI matrix: SQLite + PostgreSQL (via `docker-compose`).

### Phase 2: multi-backend router (v2.0.0-beta.1)

- [ ] `StorageBackend` table + admin CRUD endpoints.
- [ ] Backend router: ordered fallback on download, primary +
      async replication on publish.
- [ ] Health-check background task.
- [ ] Client-side fallback from lockfile URIs.

### Phase 3: publisher identity (v2.0.0-beta.2)

- [ ] `Publisher` table + registration flow endpoints.
- [ ] `cvcpkg identity init / register / status` CLI.
- [ ] Admin review endpoints (list pending, approve, reject,
      suspend, reinstate).
- [ ] Email field stored but not verified (admin review suffices).

### Phase 4: package name governance (v2.0.0-beta.3)

- [ ] `PackageName` table + ownership binding on first publish.
- [ ] Admin block/unblock/transfer endpoints.
- [ ] Typo-squatting detection (Levenshtein against blocked names).
- [ ] Seed blocked-name list from `packaging/components.yaml`.

### Phase 5: cryptographic signing (v2.0.0-rc.1)

- [ ] Ed25519 signature generation in `cvcpkg push`.
- [ ] Server-side signature verification on publish.
- [ ] Client-side signature verification on install.
- [ ] Key rotation endpoint + grace period.
- [ ] TOFU trust model with `trusted_publishers.yaml`.

### Phase 6: publisher directory (v2.0.0-rc.2)

- [ ] Public read-only endpoints for publisher profiles.
- [ ] `cvcpkg info --publisher <username>` CLI command.
- [ ] `cvcpkg info <package> --show-publisher` flag.
- [ ] HTML publisher directory page (optional, served by daemon).

### Phase 7: hardening & release (v2.0.0)

- [ ] Penetration testing against OWASP Top 10.
- [ ] Rate limiting on registration + publish endpoints.
- [ ] Comprehensive integration test suite (SQLite + PostgreSQL).
- [ ] Documentation: operator guide, publisher guide, security model.
- [ ] Performance benchmarking (target: 1000 packages, 50 publishers,
      4 backends).

---

## 11. New dependencies

| Package | Purpose | Version |
|---------|---------|---------|
| `sqlmodel` | ORM + Pydantic models | ≥0.0.22 |
| `alembic` | Database migrations | ≥1.13 |
| `asyncpg` | PostgreSQL async driver (optional) | ≥0.29 |
| `aiosqlite` | SQLite async driver | ≥0.20 |
| `aiomysql` | MySQL async driver (optional) | ≥0.2 |
| `cryptography` | Ed25519 key generation + signing | ≥43.0 |
| `python-jose` or `PyJWT` | JWT for optional OAuth flow | ≥3.3 |
| `httpx` | Async HTTP client for backend router | ≥0.27 |
| `celery` or `arq` | Async replication task queue (optional) | TBD |

All database drivers except `aiosqlite` are optional extras:
`pip install cvcpkg[server,postgres]` or `cvcpkg[server,mysql]`.

---

## 12. API versioning

The v2 server mounts all new endpoints under `/v2/`.  The existing
`/v1/` endpoints continue to work (backed by the same database) for
backward compatibility.  Deprecation timeline:

- v2.0: `/v1/` supported, no warnings.
- v2.1: `/v1/` emits `Deprecation` header.
- v3.0 (if ever): `/v1/` removed.

---

## 13. Deployment considerations

### 13.1. Single-node (lab / small team)

```bash
pip install cvcpkg[server]
cvcpkg-server run --database sqlite:///var/lib/cvcpkg/cvcpkg.db
```

SQLite mode — zero external dependencies.  Suitable for ≤5 publishers,
≤500 packages.

### 13.2. Production (multi-node)

```yaml
# docker-compose.yml sketch
services:
  db:
    image: postgres:17
    environment:
      POSTGRES_DB: cvcpkg
      POSTGRES_USER: cvcpkg
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
  server:
    image: ghcr.io/transfix/cvcpkg-server:2
    environment:
      DATABASE_URL: postgresql+asyncpg://cvcpkg:@db:5432/cvcpkg
      CVCPKG_STORAGE_PRIMARY: s3://cvc-packages/v2/
      CVCPKG_STORAGE_FALLBACK: https://github.com/transfix/libcvc-deps/releases/download/
    deploy:
      replicas: 3
```

### 13.3. Air-gapped / offline

An operator runs `cvcpkg mirror sync --from https://pkg.cvc.example.org
--to file:///mnt/packages` on an internet-connected machine, then
transfers the local directory to the air-gapped network.  The
air-gapped server serves from `file://` backend.

---

## 14. Security model summary

| Threat | Mitigation |
|--------|------------|
| Name squatting / typo-squatting | Admin review + Levenshtein detection + pre-reserved names |
| Compromised publisher key | Admin suspend → revoke all tokens + yank all packages |
| Tampered archive in transit | SHA-256 in catalog + Ed25519 signature verification |
| Tampered archive at rest | Backend stores are append-only from the server's perspective; integrity checked on read |
| Unauthorized publish | Token-scoped to publisher + name ownership check |
| Replay attack (re-publish old version) | UNIQUE constraint on (name, version, platform, arch, config, link) |
| Audit log tampering | Chained SHA-256 hashes (carried forward from 1.x) |
| Credential leakage | HMAC-hashed tokens; raw shown once at creation |
| Denial of service | Rate limiting on publish + register endpoints |
| Privilege escalation | Role hierarchy enforced server-side; admin role requires manual DB grant |

---

## 15. Open questions

1. **OAuth / OIDC integration**: Should we support "Log in with GitHub"
   for publisher registration?  This would let us auto-verify GitHub
   org membership (e.g. `transfix` org → auto-approve).  Adds
   complexity; defer to v2.1?

2. **Transparency log**: Should published artifacts be logged to a
   Sigstore-style transparency log?  Valuable for auditability but
   adds an external dependency.

3. **Artifact attestation**: Should we produce SLSA provenance
   attestations for CI-built packages?  The recipe-build workflow
   already runs in a known GitHub Actions environment.

4. **Quota management**: Per-publisher storage quotas?  Not needed
   for CVC-internal use but relevant if the registry opens to the
   broader scientific computing community.

5. **Webhook notifications**: Should the server emit webhooks on
   publish / yank events so CI systems can auto-update?

6. **Federation**: Should two cvcpkg-server instances be able to
   mirror each other's catalogs (peer-to-peer registry federation)?
