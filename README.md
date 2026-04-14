# BeatzLock Authenticator

This project has two parts:

- `otp_backend/` - Django backend API and admin
- `otp_auth_app/` - Flutter client app

## Project Structure

```text
totp_app/
├── otp_backend/
└── otp_auth_app/
```

## 1. Run The Django Backend

Open a terminal in the project root:

```bash
cd otp_backend
```

Install backend dependencies:

```bash
pip install -r requirements.txt
```

Run migrations:

```bash
python manage.py migrate
```

Start the backend server:

```bash
python manage.py runserver
```

Default backend URL:

```text
http://127.0.0.1:8000/
```

Admin panel:

```text
http://127.0.0.1:8000/admin/
```

## 2. Run The Flutter App

Open a second terminal in the Flutter app folder:

```bash
cd otp_auth_app
```

Install Flutter packages:

```bash
flutter pub get
```

## Windows

### Debug Run

Clean and run on Windows desktop:

```bash
flutter clean
flutter pub get
flutter run -d windows
```

If you do not need a clean rebuild:

```bash
flutter run -d windows
```

### Release Build

Build a Windows release executable:

```bash
flutter build windows --release
```

## Kali Linux

### Debug Run

Clean and run on Linux desktop:

```bash
flutter clean
flutter pub get
flutter run -d linux
```

If you do not need a clean rebuild:

```bash
flutter run -d linux
```

### Release Build

Build the Linux release app:

```bash
flutter build linux --release
```

## Android

Make sure an Android phone is connected with USB debugging enabled, or start an Android emulator first.

Check available devices:

```bash
flutter devices
```

If Flutter does not detect any Android device, check `adb` first:

```bash
adb devices
```

If `adb devices` shows no connected devices, restart the ADB server and check again:

```bash
adb kill-server
adb start-server
adb devices
```

If no physical device appears, list the available Android emulators:

```bash
flutter emulators
```

Example output:

```text
1 available emulator:

Id             • Name           • Manufacturer • Platform
Pixel_6_API_34 • Pixel 6 API 34 • Google       • android
```

### Start an Emulator on Ubuntu

Launch an emulator from the terminal with:

```bash
flutter emulators --launch <emulator-id>
```

For example:

```bash
flutter emulators --launch Pixel_6_API_34
```

After the emulator starts, verify it is available:

```bash
flutter devices
```

### Start an Emulator on Windows

If you are using Windows, you can start the emulator from Android Studio:

1. Open Android Studio.
2. Click `More Actions` on the welcome screen, or open `Tools > Device Manager` from a project.
3. In `Device Manager`, find your virtual device.
4. Click the `Play` button to start the emulator.
5. Wait for Android to finish booting, then run:

```bash
flutter devices
```

If the emulator still does not appear in Flutter, run:

```bash
flutter doctor
```

You can also try:

```bash
flutter devices --device-timeout 20
```

For additional troubleshooting, visit:

- https://flutter.dev/setup/
- https://developer.android.com/studio/run/managing-avds

### Debug Run

Run on Android:

```bash
flutter clean
flutter pub get
flutter run -d android
```

If you want to target a specific Android device, first copy the device id from `flutter devices`, then run:

```bash
flutter run -d <device-id>
```

### Release Build

Build a release APK:

```bash
flutter build apk --release
```

Build an Android App Bundle:

```bash
flutter build appbundle --release
```

## Quick Start

Run the backend first:

```bash
cd otp_backend
python manage.py migrate
python manage.py runserver
```

Then run the Flutter app in another terminal.

### Windows

```bash
cd otp_auth_app
flutter pub get
flutter run -d windows
```

### Kali Linux

```bash
cd otp_auth_app
flutter pub get
flutter run -d linux
```

### Android

```bash
cd otp_auth_app
flutter pub get
flutter run -d android
```

## Deployment Script

If you are deploying on the server, use:

```bash
chmod +x deploy.sh
./deploy.sh
```

Be careful when running the deployment script on a live server.
