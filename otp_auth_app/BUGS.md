# Bugs

[x] 1. The DELETE confrimation button gooes into typing filesd on landscpe on a tablet also I doubt on a landscpe phone too - Low severity

      Fixed in 1.8.1+46: every AlertDialog that holds a text field is now
      `scrollable: true`, so content and buttons scroll together and the
      actions stay reachable in landscape. The three dialogs that already
      wrapped their content in a SingleChildScrollView were left alone.

[x] 2. If a user had not generated a pdf code like force the user to do so when they first sign up/login only for user who have choosen to log in not the offline ones. Like add a pop upto tell them they must download that pdf i is reqyurement and store them safely.
The pop must apper on all devices fro alredy logged in user without the recovery pdf codes, Like a user can click send request to save pdf t dwonload folder on primary device but you get my flow? right.

      The prompt exists (`_checkBackupCodeRequirement` in
      `lib/screens/home_screen.dart`). As of 1.8.1+46 it also has a "Later"
      button, so a user is never stuck in it -- it comes back on the next
      launch until the PDF is saved.

## Fixed in 1.15.1 (Build 56)

Sign-in with an emailed code failed as "Invalid email or password":

- DRF runs `DEFAULT_AUTHENTICATION_CLASSES` on any request carrying an
  `Authorization` header, before permission classes. So a stale or revoked token
  makes `DeviceSessionJWTAuthentication` raise `AuthenticationFailed` -- a 401 --
  even on an `AllowAny` view. `_friendlyRequestError` maps 401 to "Invalid email
  or password", so a sign-in with perfectly good credentials reported bad
  credentials, and the emailed code looked like the thing at fault.
- The asymmetry that made it confusing: `send2FACode` and `verify2FACode` never
  call `_updateAuthHeader`, so they ran with whatever the shared Dio instance
  happened to be carrying. `login` calls it as its first statement, which is
  what set the stale header. The code really was sent, and really was accepted;
  the sign-in that followed is what 401'd.
- Fixed with a Dio request interceptor that strips `Authorization` from the
  endpoints that exist to create a session: login, register, passwordless
  start/poll, the 2FA pair, password reset, and the three recovery-code paths.
  Done centrally rather than per call site so a new auth endpoint cannot
  reintroduce it by forgetting.
- `test/auth_header_test.dart` pins both directions: the paths that must be
  stripped, and the authenticated ones that must keep the header -- stripping
  those would break them outright.

## Fixed in 1.15.0 (Build 55)

Import could not run on Linux:

- `ImportFilePickerService` gated desktop picking on `Platform.isWindows` and
  called `file_selector_windows` directly, so a Linux or Fedora user had no way
  to get accounts into the app at all. It now uses the umbrella `file_selector`,
  which covers Windows, Linux and macOS through the same call, with the Android
  method channel unchanged. The dialog also filters to `.bl`, `.txt` and
  `.json` rather than offering every file on the machine.

Import did not read the app's own encrypted export:

- The `.bl` backup added in 1.13.0 is JSON with an encrypted payload, so the
  plain parser found nothing in it. `OtpExportService.looksLikeEncryptedExport`
  recognises it cheaply, and only then is a passphrase asked for -- a plain
  otpauth file or another authenticator's export never prompts for one it does
  not need. The plain `.txt` export already parsed, through `_parseOtpAuthUri`.

Duplicate detection was name-only:

- Imports were deduplicated on service plus label. The same account exported
  from another authenticator usually comes back labelled differently, so it
  imported again and left two entries generating identical codes with no way to
  tell them apart. Secrets are now compared too, normalised for whitespace,
  padding and case.
- The result names what it skipped -- "Already in your vault: GitHub, AWS" --
  rather than reporting a count. The running sets are also updated as the import
  proceeds, so a file containing the same account twice no longer imports it
  twice.

Export restricted to the primary device:

- An export writes every secret the account has into one file, which is worth
  pinning to the device the account already treats as authoritative. Import is
  deliberately left open to any device: it only adds accounts, and a device that
  has just been set up is exactly the one that needs it.
- A device that is not signed in counts as its own primary, so an offline vault
  stays exportable. Enforced in `_exportAllAccounts`, not only described in the
  tile.

Passwords and Secure Self Text removed:

- Seven files deleted, and references cleared from `sync_service` (107 of them),
  `otp_vault_snapshot_service`, `encryption_service`, `main`, and three screens.
  Snapshots keep the password fields in their stored record format so existing
  snapshots still parse; nothing reads them back.
- Neither was ever a table. Both were `EncryptedData` rows keyed by
  `data_type`, which is why removing them touches no schema. Migration `0020`
  deletes those rows: they are end-to-end encrypted, nothing can read them, and
  nothing will ask for them again.
- **Passwordless sign-in was not touched.** It is a separate feature -- the
  typed four-digit approval -- and `PasswordlessLoginRequest`,
  `passwordless_login_screen` and `passwordless_requests_screen` all stay. The
  names are similar enough that this has already been confused once in this
  project's history.

Caught by the lints enabled in 1.14.0:

- `use_build_context_synchronously` flagged the export gate added in this
  release: a `BuildContext` used after an await with no `mounted` check between.
  Worth recording that the rule earned its place within one release of being
  turned on.

## Fixed in 1.14.0 (Build 54)

The last three from the audit. Done together at the user's direction, after
1.13.0 was verified in use -- signed out, signed back in, 44 accounts synced.

Hand-rolled authenticated encryption replaced with AES-256-GCM:

- The previous construction was a SHA-256 keystream with an HMAC over it:
  encrypt-then-MAC, random nonce, constant-time compare. Not broken as far as
  anyone could tell, which is not the standard for the app holding someone's
  second factor.
- Now `GCMBlockCipher(AESEngine())` from pointycastle, written as `bl3:`. The
  key is `sha256(key|aes256gcm|context)`, the nonce is 12 random bytes, and the
  context is authenticated as associated data as well as mixed into the key --
  so swapping a payload between contexts fails the tag rather than merely
  deriving a wrong key.
- `InvalidCipherTextException` is re-thrown as `FormatException`, which is what
  every existing caller already handles for a wrong key or altered payload.
- `bl2:` stays readable, so stored data migrates on its next write. The
  unauthenticated original stays gated behind the explicit flag.
- pointycastle was chosen over `cryptography` because its API is synchronous.
  The async one would have meant making ~30 call sites async, in the middle of
  a crypto change, which is how mistakes get in.

Secure storage moved to the platform keychain:

- Tokens, the vault key and the per-install local secret lived in
  SharedPreferences behind a key derived from hostname, OS username and home
  directory -- all readable by anything already on the machine, which is the
  only case that encryption existed for.
- Now DPAPI / Keychain / Keystore / libsecret via flutter_secure_storage.
  Values written under the old scheme move across the first time they are read,
  and the preference copy is deleted so the weaker one is not left behind as a
  second source of the same secret.
- The old path stays as a fallback, chosen by a write-read-delete probe rather
  than by assuming the plugin's presence means a working backing store -- which
  is exactly how Linux without libsecret fails. Locking someone out of their
  vault to improve key storage is not a trade worth making.

Push listeners outlived the session:

- `PushMessagingService` stored three `StreamSubscription`s and never cancelled
  them, and had no teardown at all. After a sign-out the app kept receiving and
  acting on push messages addressed to the account that had just left.
- `dispose()` cancels all three and clears the initialisation future, and
  `logout` calls it.

Static analysis:

- `use_build_context_synchronously`, `cancel_subscriptions`, `close_sinks`,
  `empty_catches` and `unawaited_futures` are now enforced. Between them they
  describe most of the defects in this file.
- Notably it found **no** `use_build_context_synchronously` violations: the
  screens were already careful with context across awaits, contrary to a
  hand-rolled grep that suggested dozens. Worth recording -- the regex was
  wrong, the analyser was right.
- `avoid_slow_async_io` is deliberately left off. It advises swapping async
  `dart:io` for the synchronous twin, which blocks the isolate; on a UI thread
  that trades a small per-call cost for visible jank.
- Fire-and-forget calls in `home_screen` are now explicit `unawaited(...)`
  rather than bare, so a future that starts failing is not silently ignored.

Not done:

- A GUI sweep still needs someone looking at running screens. The static audit
  above is what can be checked without that.

## Fixed in 1.13.0 (Build 53)

Server accepted any version and blindly overwrote:

- `SyncViewSet.sync` was a bare `update_or_create` that took the client's
  version number without comparing it and kept no previous copy. Any client
  could replace a vault outright, including one that had just failed to decrypt
  what was there. The client-side refusal added in 1.9.0 was the only thing
  standing in the way, and a rule about not destroying data only means something
  where the data lives.
- It now takes the row `select_for_update` inside a transaction and rejects an
  upload whose version is not ahead of what is stored, returning 409 with
  `conflict: true` and the current version. Equal versions are rejected too:
  two devices that both read v5 and both send v6 means the second built its
  upload without seeing the first.
- `syncAccounts` treats that 409 as a signal rather than an error -- it restarts
  the cycle once, which re-reads the newer copy, merges it, and only then
  writes. A second conflict is left for the next scheduled sync.
- Covered by `SyncVersionGuardTests`.

Snapshot restore replaced the cloud:

- `uploadCurrentAccountsAsAuthoritative` and its password counterpart uploaded
  local data over the stored vault without reading it, and reset
  `deleted_accounts` to `'[]'` -- so a restore silently discarded anything that
  existed only on another device, and resurrected every account the user had
  ever deleted.
- Both now merge the stored copy first, carry the deletion list forward instead
  of clearing it, and refuse outright if this device cannot read what is stored.
  A restore means "make my accounts look like this snapshot", not "discard
  whatever else is in the cloud".

No bulk export:

- The only way out was the per-account QR screen: 44 accounts meant 44 scans,
  for an app where the user may hold the only copy of their seeds.
- `OtpExportService` writes either an encrypted backup -- passphrase through the
  same PBKDF2 cost as the vault key, sealed with the authenticated cipher -- or
  plain `otpauth://` URIs for importing elsewhere, behind an explicit
  confirmation that says what the file contains.
- It reads local storage, not the cloud, so it works when sync is broken, which
  is when it is most needed. URI components are percent-encoded: a label holding
  a slash or an ampersand would otherwise produce a URI that imports as
  something else.
- `decodeEncryptedExport` honours the iteration count recorded in the file, so
  raising the shipped cost later does not strand old exports.

Django query performance:

- Every one of `AppNotification`, `DeviceSession`, `PasswordlessLoginRequest`,
  `BulkAccountDeleteRequest` and `BackupCodeGenerationRequest` is read as
  `filter(user=...)` and then ordered by `created_at` or `last_seen_at`. Django
  indexes the foreign key column alone, which finds the user's rows and then
  leaves the database sorting them.
- Composite indexes matching the queries as actually issued, in migration
  `0019`. Also `(status, expires_at)` on the three request models: the
  `_expire_stale_*` sweeps run on nearly every related request and scanned every
  pending row in the table without one.
- This is index work driven by reading the query patterns, not profiling. It is
  the part that can be done without production data; anything further needs a
  slow endpoint or real timings.

Still open, deliberately:

- `authenticatedEncrypt` is hand-rolled. Replacing it with AES-GCM is correct
  and is *not* batched here: it is a third vault-format migration, and 1.12.0's
  is not yet in the user's hands. Two unshipped format changes at once is how
  the failures earlier in this file happened.
- `SecureStorageService` still derives its key from hostname, username and home
  directory. Platform keychain (DPAPI / Keychain / Keystore) is the fix, and is
  its own migration with its own failure modes.
- No GUI sweep. Defects found in passing have been fixed; the screens have not
  been audited.

## Fixed in 1.12.0 (Build 52)

The primitives, after 1.11.0 fixed the structure. The keyring was sound sitting
on top of a cipher that could be broken without the password and a KDF that was
one SHA-256.

Synced vault encrypted with a repeating-key XOR (critical):

- `otp_accounts` -- the OTP secrets themselves -- were stored under
  `simpleEncrypt`: the 32-byte key XORed repeatedly over JSON whose first 32
  bytes are guessable (`[{"id": "a1", "service": ...`). 32 bytes of known
  plaintext is the entire key. Demonstrated against the real functions, key
  recovered exactly, secrets read out; password strength never entered into it.
  Anyone with the stored blob -- server operator, database backup, a copied file
  -- had every seed.
- It now uses the authenticated format already used for password entries and
  secure texts, under its own context. Reads accept the old format only behind
  `allowLegacyPlaintextFallback`, which the migration paths pass and nothing else
  does, so the vault converts on first sync and the downgrade closes behind it.
- The `bl2:` fallback in `authenticatedDecrypt` was itself the downgrade: strip
  four characters and the MAC check vanished with them. It now throws unless a
  caller explicitly asks for the legacy read.

No key derivation function:

- `generateKey` is a single SHA-256. Against a stored password-wrapped key that
  is no work at all -- billions of candidate passwords a second on a GPU.
- Password wrapping goes through PBKDF2-HMAC-SHA256 at 210,000 iterations
  (OWASP floor). Implemented in-repo rather than adding a dependency, and
  checked against published vectors in `test/kdf_test.dart` including the
  multi-block case -- those vectors are the reason hand-rolling it is
  acceptable, so they must keep passing.
- Measured at ~1.7s on this desktop for 210,000. That cost is the point, but it
  made several operations visibly slow, which is what the progress dialogs are
  for.
- Keyrings record `kdf_iterations`. A keyring written under the old derivation
  still opens, and is re-wrapped at the current cost the first time it does.
  The vault is never touched by that.

Local vault key derivable from the email address:

- `encryptSecret` derived from `generateKey(userId, salt)` where `userId` is the
  account email -- public. Anyone with the `.hive` file computed the same key.
  Obfuscation in the shape of encryption. (It is also why local data survived
  every sync failure this month; useful, but not a security property.)
- A random per-install secret now goes into that derivation, stored in secure
  storage and configured in `main` before any box opens. Values written before
  it stay readable and are rewritten on next save.
- Done as a configured secret rather than by threading a key through the ~34
  call sites that pass a userId. A first attempt at that refactor left
  `encryptSecret` taking the email *as* the key -- both are `String`, so it
  analysed clean while being worse than what it replaced. Noted because the type
  system will not catch that class of mistake here.

Progress feedback:

- Saving the recovery PDF from Settings, unlocking sync, repairing sync and
  checking a recovery code ran with no indication. `lib/widgets/
  blocking_progress_dialog.dart` covers them; `home_screen` already had its own
  helper and was left alone.

Known and deliberately not changed:

- `flutter_local_notifications` is held at 21.x by the local
  `flutter_local_notifications_windows` fork, whose Windows implementation is
  deliberately stubbed and which requires platform-interface ^11. Moving to 22.x
  means bumping that fork to ^12 and re-verifying the stub. `pub upgrade
  --major-versions` correctly changes nothing.
- `authenticatedEncrypt` is a hand-rolled SHA-256 keystream plus HMAC-SHA256,
  encrypt-then-MAC with a random nonce and a constant-time compare. Structurally
  sound but not a reviewed primitive; AES-GCM or XChaCha20-Poly1305 from a real
  library would be better.
- `SecureStorageService` still derives its own key from hostname, username and
  home directory -- all discoverable on the machine. The per-install secret it
  now holds is only as good as that. Platform keychain (DPAPI, Keychain,
  Keystore) is the real fix.
- Still open from earlier: the server's blind `update_or_create`, snapshot
  restore replacing the cloud, and no bulk export.

## Fixed in 1.11.0 (Build 51)

The vault key no longer comes from the account identity and password.

Every serious failure in this project traces back to that one derivation.
Lowercasing the email in the email-only migration changed the key. An account
whose username was never the email could not derive it at all. A password
change had to rewrite the entire vault, and did it by uploading one device's
copy over the stored one. A password reset -- which by definition happens
without the old password -- sealed the vault under a key nobody could ever
derive again. Each of those was fixed on its own; this removes the thing they
had in common.

The design:

- The vault is encrypted with a random data key that never changes
  (`EncryptionService.generateVaultDataKey`).
- That key is stored wrapped, in a `vault_keyring` blob: once under the
  password, once under each recovery code. Wrapping is authenticated, and the
  password and code wraps use different contexts so neither can be replayed as
  the other.
- The password wrapping key is `generateKey(password, 'vault_keyring|<salt>')`
  with a random per-account salt stored beside it. There is no identity in it,
  so how the address is spelled cannot matter any more.
- No backend change. The keyring rides the existing sync endpoints, and the
  server only ever holds wrapped bytes.

What this deletes rather than adds:

- `changePassword` re-wraps thirty-two bytes and does not touch the vault. The
  whole class of "a password change lost synced data" is gone, not guarded.
- Recovery codes wrap the data key, which does not move, so they survive
  password changes with nothing to redo. The escrow chain from 1.10.0 existed
  only to work around a key that changed; it stays for accounts not yet
  upgraded and can go once they are.
- `repairCloudVaultKey` and the candidate-key negotiation become transition-only
  machinery, needed until an account has a keyring and not after.

Migration, and why it is ordered the way it is:

- `_resolveVaultKey` asks the keyring first. With no keyring it falls back to the
  legacy derivation, and upgrades the account once, in place.
- The keyring is written **before** the vault is re-encrypted. If the
  re-encryption then fails, the vault is still readable under the legacy key,
  resolution falls back to it, and the upgrade retries. The other order would
  leave a vault nothing could open, which is the exact failure this release is
  about.
- `_reEncryptStoredVault` reads each blob before writing it and stops at the
  first one it cannot read, so it never replaces what it could not verify.
- An account whose vault nothing can open is not upgraded at all. Writing a
  keyring for a vault this device cannot re-encrypt would strand it.

Still open, unchanged by this:

- `SyncViewSet.sync` is an `update_or_create` that takes the client's version
  without comparing it and keeps no previous copy. The client refuses to write
  over what it cannot read; the server still would.
- Snapshot restore uploads local data as authoritative with `deleted_accounts`
  reset. Deliberate for a restore, but it is a replace-the-cloud path.
- There is no bulk export. A user holding the only copy of their accounts has
  no way to get them all out at once.

## Fixed in 1.10.0 (Build 50)

App -- a password reset orphaned the synced vault, permanently and silently:

- The vault key is `sha256(identity + password)`. `resetPassword` and
  `resetPasswordWithRecoveryCode` post a code and a new password and nothing
  else; the server changes the password and never touches `EncryptedData`, and
  it cannot do better -- the vault is end-to-end encrypted and the device doing
  the reset is signed out and does not know the old password. The vault stayed
  locked under the pre-reset key, which nobody could derive again. No warning,
  no recovery, and the account list simply came up empty afterwards.
- Two things now stand between a user and that. The reset screen says what a
  reset costs before they go through with it, including that accounts already on
  a signed-in device are unaffected. And the vault key is escrowed under the
  recovery codes, so the PDF they are already required to save is a genuine way
  back rather than only a way into the account.

App -- vault key escrow:

- `EncryptionService.wrapVaultKey` seals the vault key under
  `generateKey(normalizedCode, 'vault_key_escrow_salt')`, one entry per code,
  stored as `vault_key_escrow` through the existing sync endpoints. No new
  model, no migration, and the server only ever holds the wrapped blob.
- Authenticated, deliberately: a wrong code has to fail rather than return a
  plausible wrong key that would then be handed to the vault as if it were real.
  It is also randomised per wrap, so the stored blob is not a fingerprint of the
  key.
- The escrow is written at the one moment the app holds the codes in plaintext:
  when a recovery PDF is generated. `_build_backup_code_pdf_payload` already had
  them, so the download returns them in `X-Backup-Codes` and the approve
  endpoint in `codes`. Those are the same codes inside the PDF going to the same
  authenticated user, so nothing new is disclosed; the app wraps the key and
  drops them without storing them.
- Re-keys would otherwise strand an escrow, because rebuilding `wrapped_keys`
  needs codes the app no longer has. Instead each re-key appends the new key
  sealed under the one it replaces, and recovery walks that chain. Codes saved
  before a password change still reach the current key.
- `restoreVaultKeyFromRecoveryCode` accepts a key only once it has actually
  opened the stored vault, and writes nothing to the cloud. Surfaced as "Unlock
  Sync With A Recovery Code" in Settings.

Known limits, worth stating plainly:

- Escrow protects vaults from this version forward. A vault already orphaned by
  a reset before it has no escrow entry and cannot be recovered by this or any
  other change -- there is nothing to unwrap.
- Recovery codes generated before this version have no vault key attached.
  Generating a fresh set is what creates the escrow.
- The deeper fix is to stop deriving the vault key from the password at all: a
  random vault key, wrapped under both a password-derived key and the recovery
  codes, means a password change re-wraps one small blob instead of rewriting
  the whole vault, and no reset can ever orphan anything. The escrow chain here
  is the pragmatic version of that and carries a little complexity the redesign
  would remove.

## Fixed in 1.9.1 (Build 49)

The stored vault is authoritative. Nothing writes to it without having read it
first, so every write carries the stored content forward instead of replacing
it. Where nothing can read it, the write does not happen: that ciphertext is
the only copy of whatever it holds, and one device having lost the key is not
evidence that no device has it.

Security -- passwordless approval:

- The approving phone was handed the correct code among three, in
  `verification_choices` on every request payload, and tapped one. That is a
  one-in-three guess for anyone holding an unlocked primary phone without ever
  seeing the requesting device, and `approve` counted nothing, so the guess
  could simply be repeated inside the request's three-minute window. The code is
  typed now; the field, `_build_passwordless_choices`, its seeded shuffle and
  the `selected_code` request key are all gone, so nothing serves the code or a
  candidate list and nothing accepts a tapped answer. `hashlib` and `random`
  left `api/views.py` with them.
- `PasswordlessLoginRequest` carries the same attempt budget as every other code
  in this codebase (`MAX_ATTEMPTS = 5`, mirroring `DeleteOTPCode`). A wrong code
  spends one and reports what is left; a spent budget retires the request, and
  the correct code cannot revive it. Migration `0018`.
- Approving needs the updated app on the primary phone. An older build has no
  choices to render and no field to type into, so its Accept stays disabled.
- Bulk-delete and backup-code approvals carry no code at all -- the primary
  phone simply approves -- so the guessing weakness never applied to them.

App -- `changePassword` destroyed synced data (pre-existing):

- It read only this device's accounts, then uploaded them over the stored vault
  with `deleted_accounts` reset to `'[]'`. Anything in the cloud and not on that
  device was gone, and every tombstone with it, so deleted accounts could
  return.
- Worse, it re-encrypted `otp_accounts` alone. `password_entries` and
  `secure_messages` stayed under the previous password's key while the device
  moved to the new one, which made them permanently unreadable -- a silent,
  total loss of synced passwords and secure texts on every password change.
- It now delegates to `repairCloudVaultKey`, which reads the stored vault under
  a key that opens it, merges, and rewrites all three data types. When the
  rewrite cannot happen the password change still stands, the stored vault is
  left untouched rather than overwritten, and the device is told to repair from
  somewhere that can read it.

App -- vault re-key:

- `repairCloudVaultKey` in `lib/services/sync_service.dart` rewrites the vault
  under the key the current canonical identity and password derive, for the case
  where this device holds a working key and other devices derive a different
  one. Surfaced as "Repair Cloud Sync Key" in Settings.
- It runs only after some derivable key has opened the stored vault, and it
  merges that content in first, so the rewrite is a superset and never a
  substitution. Versions and deletion lists are carried forward rather than
  reset. A failed run restores the key the device started with.
- Where no key opens the vault, it refuses and explains, leaving the stored
  bytes alone.
- Two earlier cuts of this were wrong and are worth not repeating. The first
  read the cloud to decide whether it could run, which meant it could never run
  where it was needed -- a device needs repairing precisely when its key will
  not open the cloud, so every device offered "Repair" and every one bailed out.
  The second overreacted by publishing local data over the stored vault, which
  turned a recovery tool into a way to lose the only copy of anything the
  device did not happen to have.

## Fixed in 1.9.0 (Build 48)

App (`otp_auth_app`), sync:

- A fresh sign-in could not open the cloud vault, so a new device arrived signed
  in, receiving notifications, showing no accounts. The vault key is
  `sha256(identity + password)` where the identity is whatever the API returns as
  `user["username"]`. That was a stored username column until 1.8.2 made it the
  email address, and `users/migrations/0002_email_only_accounts.py` lowercased
  every address in place. Hashing is case-sensitive, so an address with any
  capital in it derives one key on an install that signed in before the migration
  -- which keeps working from the key in secure storage -- and a different key on
  one that signs in after. `login`, `_applyAuthenticatedResponse` and
  `unlockSyncOnCurrentDevice` now build every spelling of the identity they can,
  probe them against the real cloud payload, and keep the key that opens it,
  canonical derivation first. See `_resolveVaultEncryptionKey` in
  `lib/services/sync_service.dart` and `test/vault_key_negotiation_test.dart`.
- Data loss: `syncAccounts` uploaded after a failed decrypt. A wrong key left
  `cloudAccountsMap` empty, and the merge-then-upload wrote that empty vault over
  the cloud copy -- `SyncViewSet.sync` is an `update_or_create` that takes the
  client's version number without comparing it, and keeps no previous copy. Only
  the other device still re-uploading its own accounts hid it. The upload is now
  refused when the download produced content that would not decrypt.
- Both failures were silent. `simpleDecrypt` is unauthenticated, so a wrong key
  produced garbage, `jsonDecode` threw, and the handler wrote a `debugPrint` and
  returned. A mismatch now sets `lastErrorMessage` and makes
  `isSyncLockedOnCurrentDevice` true, which surfaces the existing "Unlock Sync On
  This Device" tile instead of an empty account list. The passwordless approval
  path already transfers the key rather than deriving it, and is the recovery
  route for an account whose old username was not its address at all -- the
  dropped column means nothing can reconstruct that identity.

Backend (`otp_backend`):

- `report_diverging_usernames` was meant to name the accounts this would break
  and missed the ones most likely to be affected. It compared
  `lower(username) <> lower(btrim(email))`, hiding case-only divergence -- the
  exact class that breaks key derivation, and the common one, since the app wrote
  the address the user typed into both columns. The comparison is exact now.

Dependencies:

- dio 5.9.2 to 5.11.0, path_provider 2.1.5 to 2.1.6, file_selector_windows and
  34 transitive packages, all within their existing constraints.

## Fixed in 1.8.2 (Build 47)

Backend (`otp_backend`), security:

- A six-digit code could be guessed without limit. `/api/reset-password/` took an
  email, a code and a new password with no cap on attempts inside the ten-minute
  window, so guessing the code took over the account. 2FA codes and the
  delete-everything code had the same hole. Codes now carry an attempt budget of
  five, retire themselves when it is spent, and are compared with
  `constant_time_compare`. See `twofa/models.py` and `api/models.py`.
- `recover-primary-device` skipped that budget entirely by looking the code up
  by its value -- a lookup by value cannot count wrong values. It fetches the
  live code and compares it now.
- Verification codes came out of `random`, whose state is recoverable from its
  own output. The 2FA/reset code, the passwordless sign-in code and its seed,
  and the delete-everything code all use `secrets` now. The one remaining
  `random.Random(seed)` is deliberately deterministic and says so.
- Twelve endpoints echoed the exception text of a 500 back to the caller. The
  traceback was already logged; the text is behind `DEBUG` now.

Backend, correctness:

- `EMAIL_TIMEOUT` sat in `.env` and nothing read it, so Django's default of
  `None` applied and the SMTP socket had no timeout at all -- a hung mail host
  would hold a gunicorn worker open indefinitely. Every 2FA and reset code is
  sent from inside a request.
- A completed password reset could return a 500: the confirmation email was sent
  without `fail_silently` after the password had already changed.
- The admin log viewer read whole log files into memory to show the last few
  hundred lines. Logs rotate daily with no size cap. On a 50 MB file, peak memory
  went from 69.9 MB to 0.2 MB.

Performance:

- The notifications list decrypted every row five times, once per serializer
  field. A hundred rows went from about 10 ms to 2.9 ms.
- The three Fernet ciphers were rebuilt on every encrypt and decrypt.
- The downloads site asked the database once per platform and once per Linux
  distribution: `/downloads/` went from 14 queries to 4, `/downloads/archive/`
  from 26 to 1.
- The GeoLite2 database was opened, memory-mapped and torn down on every single
  download: 1.92 ms to 0.02 ms.
- `Platform.localHostname` -- a real syscall -- ran on every app storage read and
  write, deriving a key that cannot change while the process lives: 6.30 us to
  0.019 us. Verified byte-identical against the old implementation so values
  already on disk still decrypt.

App:

- The one-second OTP ticker kept running while the app was backgrounded, walking
  the vault every second and calling `setState` on a widget tree nobody was
  looking at. Mobile throttles background timers; the desktop builds do not. It
  stops on pause and refreshes immediately on resume.
- Start-up ran four independent chains of platform-channel calls one after
  another. They overlap now.

## Fixed in 1.8.1 (Build 46)

- Cancelling the device unlock prompt fell back to the in-app PIN. A device now
  uses one unlock method only: the OS lock when it has one, the BeatzLock PIN
  when it does not. See `lib/services/app_lock_service.dart`.
- Retrying a failed vault load started a second OTP ticker each time, because
  `_startTimer` chained `Future.delayed` with no handle to cancel. It is a
  single cancellable `Timer.periodic` now.
- `_showEntryDialog`, the rating dialog and the change-password dialog never
  disposed their `TextEditingController`s, leaking on every open.
- The blocking progress dialog popped whatever route was on top of the root
  navigator rather than itself, and had no way out if a request stalled.
- An `AnimationController` on the home screen was created, started and disposed
  without ever driving anything.
- The unlock method was resolved once per process and never re-checked, so a
  device that gained or lost a screen lock kept the old method until the app was
  restarted. It is now re-probed on every resume.
- A BeatzLock PIN left over from a device that later gained a screen lock stayed
  in storage forever: hidden from Settings, unchangeable, and able to become the
  only way in again if the screen lock was ever removed. Gaining a screen lock
  now deletes it, and losing one asks for a fresh PIN rather than a remembered
  one -- there is no PIN recovery flow, so a forgotten PIN was a lockout.
- Creating a PIN under duress used to ask the user to immediately type it back,
  which proved nothing.
- Shrinking the desktop window painted overflow stripes across the header and
  the code cards. There was no minimum window size: `WindowUtils` looked like it
  set one but called `MethodChannel('flutter/window').invokeMethod`, a channel
  Flutter does not have, so every call threw and was swallowed. The floor is now
  enforced natively -- `WM_GETMINMAXINFO` in `windows/runner/win32_window.cpp`
  and `gtk_window_set_geometry_hints` in `linux/runner/my_application.cc`, both
  at 480x560 logical pixels. `lib/utils/window_utils.dart` and
  `lib/services/window_service.dart` were both entirely unreferenced and are
  gone.
- The OTP card's top row put the code column in the flex with no flex factor, so
  it always took its natural width and pushed the row past its constraints. It
  now stacks the code under the account name below 260px, which also covers
  Android split-screen and small phones.
