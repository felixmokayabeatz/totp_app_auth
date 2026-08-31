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

## Fixed in 1.9.1 (Build 49)

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
- Bulk-delete and backup-code approvals were left alone. They carry no code at
  all -- the primary phone simply approves -- so the guessing weakness did not
  apply to them.

App -- vault recovery deadlock:

- 1.9.0's key negotiation recovers a vault whose key the device can still
  construct from some spelling of the address. It cannot help an account whose
  identity genuinely changed -- an old username that was never the email -- and
  the documented escape hatch for that case did not exist in practice. Transfer
  rides on passwordless approval, `_ensure_primary_mobile_session` restricts
  approval to the primary phone, and `passwordless_start` refuses outright
  unless the primary is mobile. When the primary phone is itself the device
  missing the key there is nobody left to approve, and a device cannot send
  itself a request.
- `repairCloudVaultKey` in `lib/services/sync_service.dart` breaks the deadlock
  by republishing rather than transferring: a device rewrites the cloud vault
  from its own local storage under the key the current canonical identity and
  password derive. Every other device then works from its own password.
  Surfaced as "Repair Cloud Sync Key" in Settings.
- It reads the **local** vault, not the cloud one. The first cut of this read
  the cloud, which meant it could never run anywhere it was needed: a device
  needs repairing precisely when its key will not open the cloud blob, so every
  device offered "Repair" and every one of them bailed out with "could not read
  your synced accounts". Local secrets go through
  `EncryptionService.encryptSecret`, keyed on the user id and its own salt and
  never on the password, so they stay readable however broken sync is -- if a
  device can display an account, it can republish it. Covered by
  `test/vault_key_negotiation_test.dart`.
- Cloud data is merged in first wherever any derivable key still opens it, so
  cloud-only items survive. Where none does, no device can read those items
  either; the caller has to pass `replaceUnreadableCloudData`, which the dialog
  gates behind an explicit checkbox. A device with an empty local vault and an
  unreadable cloud one is refused outright rather than publishing nothing over
  the only copy that exists.
- The Settings tile is shown on sync-locked devices too. Reading local storage
  does not need the sync key, so the locked device can be the one that fixes it.

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
