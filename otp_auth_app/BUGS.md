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
