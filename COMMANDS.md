# Commands

Everything runs from the repo root unless a command says otherwise.

---

## Local development

### The two Django servers

```bash
cd beatzlock_app
python -m venv beatzlock_v_env && . beatzlock_v_env/Scripts/activate   # first time
pip install -r requirements.txt                                        # first time
echo "DEBUG = True" > config/local.py                                  # first time
python manage.py migrate
python manage.py runserver 8005
```

`config/local.py` is git-ignored and required for local work: `.env` is a copy
of the server's and carries `DEBUG=False`, which makes `runserver` resolve
static files through a manifest that only `collectstatic` writes. Without it
the first page fails with `Missing staticfiles manifest entry`.

```bash
cd otp_backend
python -m venv totp_v_env && . totp_v_env/Scripts/activate             # first time
pip install -r requirements.txt                                        # first time
echo "DEBUG = True" > otp_backend/local.py                             # first time
python manage.py migrate
python manage.py runserver 8000
```

| | Port | URL |
|---|---|---|
| Downloads site | 8005 | http://localhost:8005/ |
| Authenticator API | 8000 | http://localhost:8000/api/ |

### The Flutter client

```bash
cd otp_auth_app
flutter pub get
flutter run -d windows        # or -d linux, -d android
```

> **The app talks to production by default.** `AppConfig.isDevelopment` is
> `false`, and every URL getter returns the `prod*` value when it is — debug
> mode does not change that. Until the `local.json` flow below is wired up, the
> only way to point a debug run at your local servers is to set
> `isDevelopment = true` in `lib/config/app_config.dart` **and set it back
> before building anything you release**.

### Pointing the app at the local servers — pending

Not wired up yet. Once it is:

```bash
cd otp_auth_app
flutter run -d windows --dart-define-from-file=local.json
```

`local.json` is created by hand and git-ignored. Nothing else changes: without
the flag every build uses the production URLs, so a release can never pick up a
local address by accident.

---

## Running through build.py

```bash
python build.py         # Windows (PowerShell)
python3 build.py        # Linux
```

Run it from the repo root; it chdirs into `otp_auth_app/` itself.

### Debug runs

| Option | Does |
|---|---|
| `8` | Run Linux (debug mode) |
| `9` | Run Windows (debug mode) |
| `10` | Run Android (debug mode) |
| `11` | Run with hot reload |

### Release builds

| Option | Produces |
|---|---|
| `1` | Linux package for this distro (.deb/.rpm) |
| `2` | Ubuntu/Debian .deb |
| `3` | Fedora .rpm |
| `4` | Windows installer (.exe) |
| `5` | Android .apk + .aab |
| `6` | Windows + APK |
| `7` | Linux package + APK |

Artifacts land in `otp_auth_app/final_builds/<platform>/<version>/`.
Metadata is appended to `otp_auth_app/build_logs/<platform>/build_log.json`.

### Utilities

| Option | Does |
|---|---|
| `12` | Clean all build files |
| `13` | Fix Windows build (clear CMake cache) |
| `14` | List previous builds |
| `15` | Open the final builds directory |
| `16` | List available devices |
| `17` | Run tests |
| `18` | Analyze code |

### Straight Flutter equivalents

```bash
cd otp_auth_app
flutter build windows --release
flutter build linux   --release
flutter build apk     --release
flutter build appbundle --release
flutter clean
flutter analyze
flutter test
```

---

## Cutting a release

```bash
# 1. Bump both, together -- they must match
#    otp_auth_app/pubspec.yaml                    version: 1.8.0+45
#    otp_auth_app/lib/config/app_build_info.dart  version / buildNumber

# 2. Write the notes, named after the version
#    beatzlock_app/release_notes/<year>/<month>/v1.8.0_45.txt
#
#    v1.8.0 (Build 45)
#
#    What's New
#    - ...

# 3. Build
python build.py         # option 4, 5, 6 ...

# 4. Publish in the admin at https://apps.felixmokayabeatz.online/beatzlock-admin/
#    App Release first  -- version, build number, the notes .txt
#    Platform Build     -- one per binary, pointing at that release

# 5. Confirm
#    /console/build-history/   what was built
#    /downloads/               what is published
```

Clients pick the release up on their next update check.

---

## Deploying the Django projects

Each project deploys itself; they share nothing.

```bash
sudo ./beatzlock_app/deploy/deploy.sh            # menu
sudo ./beatzlock_app/deploy/deploy.sh --update   # routine deploy
sudo ./otp_backend/deploy/deploy.sh  --update

sudo ./beatzlock_app/deploy/deploy.sh --status
sudo ./beatzlock_app/deploy/deploy.sh --logs
sudo ./beatzlock_app/deploy/deploy.sh --restart
sudo ./beatzlock_app/deploy/deploy.sh --django createsuperuser
sudo ./beatzlock_app/deploy/deploy.sh --database
```

| Action | Does |
|---|---|
| `--fresh` | full install: apt, PostgreSQL, virtualenv, migrate, static, superuser, service, nginx, firewall |
| `--update` | dependencies, migrate, collectstatic, re-render unit + nginx, restart |
| `--restart` | restart gunicorn, reload nginx |
| `--status` | service, port, database, migrations, certificate |
| `--logs` | gunicorn, nginx, Django |
| `--database` | create/repair, back up, restore, psql, reset |
| `--django …` | any manage.py command |
| `--renew` | renew this subdomain's certificate |
| `--uninstall` | remove the unit and nginx site; keeps code, database, .env |

A subdomain needs its DNS A record before its first deploy, or certbot cannot
issue a certificate. The script checks and tells you the exact record.
