# Aurelia PMS Storage Audit and Migration Design

**Audit scope:** repository branch `security/production-release-gate`, commit `6bb796fddbd45cb1eb02b954c1f8c5dd18fcfc91` (2026-10-13).

**Status: RELEASE HOLD.** This is a source inspection, not proof that encryption or migration has been implemented.

## Confirmed storage locations

| Location | Evidence / keys | Data and risk | Required action |
|---|---|---|---|
| WebView/browser `localStorage` | `assets/index.html`: `aurelia_pms_v3`, `aurelia_pms_v3_autobackup`, `aurelia_pms_v3_autobackup_time` | Entire serialized `DB` object is JSON. Includes guest, booking, room, financial/operational records, settings, and audit data. Plaintext at rest. | Inventory every key and schema; migrate through a native encrypted store; retain originals until verified recovery. |
| In-memory JavaScript | `let DB=loadAureliaDB()` and `save()` in `assets/index.html` | Live PMS object remains in WebView memory while app is running. | Minimize bridge payloads and avoid logging; clear transient sensitive values where feasible. |
| Local recovery snapshot | `aurelia_pms_v3_autobackup` and timestamp | Duplicates the whole database as plaintext JSON in localStorage; may be stale and is not an independently verified backup. | Replace with authenticated encrypted snapshots and explicit version/integrity checks. |
| Downloaded exports/backups | `exportJSON()`, `aureliaDownloadBackup()`, CSV/PDF/image export functions and `downloadBlob()` | JSON backup and report exports may contain sensitive records in plaintext. Android may hand files to native sharing/download flows. | Make export consent explicit; document file destinations and cleanup; provide encrypted full-backup format. Ordinary business reports need a clear policy because external CSV/PDF consumers generally expect plaintext. |
| Google Drive appDataFolder | `aureliaUploadDriveBackup()` serializes `{app,version,exportedAt,data:DB}` to JSON and uploads it directly | If OAuth is connected, current code sends unencrypted PMS JSON to Drive. Drive storage is not client-side encryption. | Disable this upload path until authenticated encryption and recovery-key handling are implemented and tested. Never represent the current path as encrypted. |
| Google OAuth token | `aureliaDriveAccessToken` JavaScript variable | Access token is held in memory for the current WebView session; it is not persisted by this variable. | Keep token lifetime and scope minimal; verify no other token persistence in deployed origin/browser state. |
| PIN / security preferences | Security UI in `assets/index.html`; native secure-storage code in `lib/main.dart` | The HTML security UI claims PIN/recovery are stored in the browser on this device; native Flutter code also stores app-lock verifier material in secure storage. These are separate trust domains until proven otherwise. | Trace all PIN functions and bridge messages; ensure the HTML PIN does not override native lock; keep secrets in Android Keystore-backed/secure storage only. |
| Flutter secure storage | `AureliaSecureVault` use in `lib/main.dart` | Intended for native lock metadata/verifier; not the PMS record store. | Review plugin configuration and failure behavior; do not mistake it for encryption of WebView localStorage. |
| Native files / cache / preferences / SQLite | Source tree includes Android native activity and Flutter wrapper; no SQLCipher dependency is present in `pubspec.yaml`. No authoritative PMS SQLite implementation was found in the inspected source paths. | No encrypted PMS database currently identified. Android/WebView may also maintain browser-managed storage/cache outside the app source. | Inspect installed-version behavior on-device and platform data locations before migration. Do not infer absence solely from source search. |
| IndexedDB / sessionStorage | No matching use found in the inspected `assets/index.html` source search. | Not confirmed as a current PMS store. | Re-scan complete deployed HTML and WebView origin storage during device testing. |

## Important data flows and hazards

1. `loadAureliaDB()` reads `aurelia_pms_v3`; if JSON parsing fails, it tries `aurelia_pms_v3_autobackup`; if both fail it returns seeded demo data. This fallback must not silently make real data appear missing. Migration must fail closed and preserve the source bytes for recovery.
2. `save()` serializes the whole database and writes the primary and local recovery snapshot in plaintext.
3. `importSelected()` currently assigns parsed JSON directly to `DB` and calls `save()`. This is a destructive replacement path without schema/version/relationship validation or a transactional rollback.
4. `aureliaUploadDriveBackup()` currently uploads plaintext JSON; it is not an encrypted backup implementation.
5. `aureliaDownloadBackup()` and `exportJSON()` create plaintext JSON backups. CSV/PDF/image exports are also intentionally readable output and require access/retention controls.
6. The native app-lock overlay and secure PIN verifier do not encrypt WebView localStorage. Locking the UI is not equivalent to protecting data at rest.

## Safe implementation sequence

1. **Freeze risky paths:** do not enable or claim encrypted Drive backup; retain current originals. Do not perform automatic destructive imports/migrations.
2. **Baseline schema:** capture the full DB top-level keys, nested record types, stable IDs, references, totals/statuses, and timestamps from source and representative synthetic fixtures. Do not put real guest data in CI artifacts.
3. **Choose encrypted store:** use a maintained SQLCipher-compatible implementation for Android, with a random database key protected by Android Keystore. Document device loss/replacement recovery separately; Keystore-wrapped keys alone are not recoverable on a replacement device.
4. **Bridge contract:** define a versioned, narrow JavaScript/native API for load/save/transactional import/export. Do not pass key material to JavaScript. Preserve UI markup and behavior while replacing persistence implementation.
5. **Migration journal:** read source without deleting it; validate schema and record relationships; write encrypted target to a new file; transactionally verify record counts, IDs, references, financial totals, settings, and timestamps; flush and reopen target; write a durable migration-complete marker only after validation. On crash/restart, resume or roll back using journal state. Keep original data until a tested backup and verified target exist.
6. **Backup format:** use a vetted authenticated-encryption format with random nonce and authenticated header (format version, app/schema version, creation time). Keep recovery credentials separate from the backup; never hardcode them. Reject wrong keys, tampering, truncation, unsupported versions, and oversized inputs before touching live data.
7. **Restore transaction:** decrypt and validate into a staging database; display target/overwrite/merge consequences; create a verified safety snapshot of current data; atomically swap only after successful validation. On any failure preserve the live database.
8. **Test and evidence:** unit/integration tests for empty/large/malformed/duplicate datasets, relationships, migration interruption at each phase, low disk, process death, repeated restore, invalid credentials, tampering/truncation, upload interruption, and old-version upgrade. Physical-device tests are separately recorded.

## Acceptance evidence still required

- [ ] Storage map reviewed against full source and installed app storage.
- [ ] Encrypted PMS database and Android Keystore key handling implemented.
- [ ] Existing-source migration is restart-safe, idempotent, and loss-tested.
- [ ] Plaintext localStorage and unsafe cloud upload removed only after verified migration.
- [ ] Authenticated encrypted backup/restore implemented and tested on a replacement device.
- [ ] Production signing identity verified and release APK certificate fingerprint recorded.
- [ ] Physical-device test matrix completed with model, Android version, expected/actual result, and defects.

Until those items are evidenced, Priority 1 is incomplete and production release must remain blocked.


## Follow-up safety controls (commit `7d9dd7b1ddadfffd779677c38135dbcabc954569`)

- The legacy Google Drive upload function now refuses to upload the plaintext JSON payload. This is a **temporary fail-closed guard**, not encrypted backup functionality.
- The legacy JSON import now refuses to replace the live `DB` until a staged, schema-validated, recoverable importer/restore exists. This is a **temporary data-preservation guard**, not a completed restore workflow.
- The UI and existing records are intended to remain unchanged; behavior for cloud backup and JSON import is intentionally unavailable while these safety holds are active.
- These changes do not encrypt `localStorage`, do not complete migration, and do not establish backup/recovery acceptance. Release remains blocked.
