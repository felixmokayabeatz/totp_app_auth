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
