# Review of proposed production backup and document services

**Status: do not merge the supplied snippets as production code.** They target a different persistence architecture from the app currently in this repository.

## Current persistence architecture

The native Flutter wrapper stores the PMS JSON payload in app-private files encrypted with AES-256-GCM. The encryption key is held in Android-backed secure storage. The WebView uses a native message bridge to save and restore JSON snapshots. There is no SQLCipher database, no `pos_transactions` / `folios` schema, and no configured Google Sign-In / Google Drive client in `pubspec.yaml`.

## Drive snippet blockers

1. **Incompatible restore target:** `openDatabase(..., password: recoveredKey)`, SQLCipher table checks, and the `aurelia_sqlcipher_key_v1` key are not connected to the existing AES-GCM JSON store. This cannot restore the current app's data.
2. **Backup pair mismatch:** restore selects the newest manifest and newest database independently. It does not prove that the manifest belongs to the selected database. A manifest should contain the exact Drive file ID, version ID, ciphertext digest, and authenticated metadata for the paired backup.
3. **Read-back verification is incomplete:** comparing remote file size with local byte length is not a checksum. Equal-length corruption is not detected.
4. **Rollback swap is not safe:** if writing the restored key fails after the staged file has been renamed to the live path, the catch block tries to rename the old backup over an existing live file. The rollback path does not first move or remove the newly installed file, so rollback can itself fail.
5. **Partial uploads and pruning:** a database upload can succeed while its manifest upload fails, leaving an orphan. The retention logic can delete the database before it successfully deletes the corresponding manifest. Listing is not paginated, and partial API failures can leave history inconsistent.
6. **Authentication and dependencies are not wired:** `GoogleAuthClient`, Google Sign-In, Google APIs, SQLCipher, and their platform configuration are absent from this repository. The supplied constructor/API calls must be checked against the pinned package versions before use.
7. **No verified recovery transaction:** there is no tested guarantee that an interrupted upload or restore preserves a known-good recoverable version end-to-end.

## Document handler snippet blockers

1. `openFileExternally` joins a caller-supplied filename to a temporary directory without applying the filename validation used by `saveFileViaSAF`. Reject path separators and dot-segment names before writing.
2. Base64 is decoded before its encoded size is bounded, allowing a large request to consume excessive memory before the decoded size check.
3. `printDocument` treats arbitrary bytes as PDF data and has no size or file-format validation.
4. Delayed temporary-file deletion is not awaited and can fail silently. Cleanup behavior must be tested with the external viewer lifecycle.
5. The proposed service is not connected to the existing native WebView message protocol and introduces dependencies that are not pinned in this repository.

## Safe implementation path

- Keep the production hold active and Google Drive upload disabled.
- Freeze the actual Flutter dependency graph and require `flutter pub get --enforce-lockfile` in CI.
- Implement Drive backup for the **existing portable encrypted backup envelope**, not a hypothetical SQLCipher database. Upload one self-contained encrypted object per version, verify downloaded bytes with a cryptographic digest, select a version by a single manifest/object ID, and validate/decrypt the complete payload before calling the existing encrypted-store write path.
- Never prune old versions until the newly uploaded version has passed read-back verification and the retention set has been fully enumerated. Keep at least one prior verified version.
- Test upload interruption, manifest corruption, equal-length byte tampering, wrong passphrases, partial deletion, app termination during restore, and rollback failure with a fake Drive backend before enabling cloud sync.
- Extend the existing native bridge with bounded save/print operations and validate MIME type, extension, decoded size, and safe filename before creating a temporary file.

## Follow-up review: unified JSON envelope and document handler proposal

The newer snippets improve the conceptual direction (one envelope and file-type checks), but are still **not safe to integrate verbatim**:

1. **The checksum is detached from the envelope.** `expectedChecksum` is supplied by the caller rather than authenticated/stored with the object. It detects corruption only when the caller has a trusted expected digest. For a downloaded backup, compute and compare against a trusted Drive metadata value or use an authenticated envelope; do not treat a checksum stored beside attacker-controlled bytes as authenticity.
2. **No envelope-size or structural bounds before parsing.** `executeAtomicRestore` decodes UTF-8/JSON and nested base64 values without an overall byte cap, field-length caps, strict field/type checks, nonce/MAC length checks, or bounded iteration policy. Apply a hard byte cap before JSON parsing and validate every field before allocating decoded payloads.
3. **Key/storage model is incompatible.** The current app does not use `aurelia_sqlcipher_key_v1`; it uses its existing AES-GCM JSON snapshot store and a different key lifecycle. The proposed code also encrypts the raw snapshot and an unrelated `dek`, then only writes the recovered key. It never commits the recovered snapshot through `AureliaEncryptedPmsStore.write`, so it is not an atomic restore and can leave key and data inconsistent.
4. **Schema checks do not match the app.** `posTransactions` and `folios` are not the current app's validated snapshot schema. Restore must use the same validator and storage write path as the app's existing portable encrypted backup.
5. **Cryptographic details need tightening.** The code uses password `codeUnits` instead of an explicitly defined UTF-8 password encoding, has no password-strength/empty-password policy, and does not bind envelope version/schema metadata as authenticated additional data. The checksum is not a substitute for AEAD authentication.
6. **The document handler is still unbounded on open/print.** `openDocumentExternally` and `printPdfDocument` decode before enforcing the 15 MiB limit. The open path does not validate the filename or extension, so path traversal/overwrite risks remain. The save path's filename regex permits `..` and its base64 length estimate should be followed by strict base64 validation and a decoded-size check.
7. **Magic bytes are only a type hint.** Four PNG bytes are insufficient to establish a valid PNG, and a PDF header alone does not prove a well-formed safe document. Keep strict bounds and use format-aware parsing where feasible; never claim this validates document safety.
8. **Temporary cleanup is fire-and-forget.** `Future.delayed` is not awaited, the delayed callback may fail, and a file may be deleted while an external viewer still needs it. Cleanup needs an explicit lifecycle policy and error handling.
9. **Dependencies and bridge integration are missing.** `googleapis`, `crypto`, `open_filex`, and `printing` are not declared in the current `pubspec.yaml`. The proposed methods are not wired to the current WebView bridge or tested against Android save/print flows.

**Decision:** keep cloud backup and document open/save/print disabled until an implementation targets the current store, has bounded parsing and a transactional commit/rollback design, passes automated corruption/failure tests, and is verified on physical Android devices.
