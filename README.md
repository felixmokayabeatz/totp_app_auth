# BeatzLock

Everything BeatzLock in one repo, as three projects that share nothing but the
checkout:

```text
beatzlock_project/
├── beatzlock_app/     downloads & ratings site   (Django)
├── otp_backend/       authenticator API          (Django)
├── otp_auth_app/      Flutter client + the native build tooling
├── build.py           wrapper that runs otp_auth_app/build.py
└── github.py          git identity helper
```

That is the whole top level. Each project owns everything it needs — its
`.env`, `requirements.txt`, virtualenv, static files, templates, nginx config
and its own `deploy/deploy.sh` — so working on one never means reading the
other, and neither deploy script knows the other exists.

## The two Django projects

Separate settings, separate databases, separate `auth_user` tables, separate
subdomains, separate systemd units, separate deploy scripts.

| | Downloads site | Authenticator API |
|---|---|---|
| Where | `./beatzlock_app/` | `./otp_backend/` |
| Deploy | `./beatzlock_app/deploy/deploy.sh` | `./otp_backend/deploy/deploy.sh` |
| Subdomain | `apps.felixmokayabeatz.online` | `api.felixmokayabeatz.online` |
| Database | `felixmokayabeatz_beatzlock_db` | `felixmokayabeatz_totp_db` |
| DB role | `Felix_Apps_Administrator` | `Felix_Apps_Administrator` |
| Settings | `beatzlock_app/config/settings.py` | `otp_backend/otp_backend/settings.py` |
| `.env` | `beatzlock_app/.env` | `otp_backend/.env` |
| WSGI | `config.wsgi` | `otp_backend.wsgi` |
| Gunicorn port | `8012` | `8002` |
| Dev port | `8005` | `8000` |
| systemd unit | `beatzlock` | `beatzlock-api` |
| Virtualenv | `beatzlock_app/beatzlock_v_env` | `otp_backend/totp_v_env` |
| Admin | `/beatzlock-admin/` | `/beatzlock_admin/` |
| Sign-in | email address | email address |
| Django apps | `beatzlock_app`, `console` | `accounts`, `api`, `twofa`, `beatzlocklogs` |
| Static | `beatzlock_app/static/` + each app's own `static/` | `otp_backend/static/` |

Both roles are the shared `Felix_Apps_Administrator` used by the other
felixmokayabeatz sites on the host, so neither `deploy.sh` ever rewrites its
password — each only creates the role if nothing on the host has one yet.

### What each one serves

**Downloads site** — `/downloads/`, `/downloads/archive/`, `/rate/`,
`/legal/terms-of-service/`, `/legal/privacy-policy/`, the `/api/update-check/`
and `/api/ratings/…` JSON the native apps read, and the staff console at
`/console/stats/`, `/console/review-replies/`, `/console/build-history/`.

**Authenticator API** — `/api/` for the native clients: auth, sync, device
sessions, passwordless login, backup codes, 2FA and recovery codes, plus the
log viewer at `/beatzlock_admin/logs/`. `/` redirects to the main site.

### Where the files live

Each Django app carries what belongs to it, so an app folder can be read,
moved or copied without hunting for its assets:

| | |
|---|---|
| `beatzlock_app/beatzlock_app/data/GeoLite2-Country.mmdb` | country lookup for the download stats; committed, the stats view reads it at runtime |
| `beatzlock_app/beatzlock_app/static/beatzlock_app/` | assets owned by the downloads app |
| `beatzlock_app/console/static/console/` | the staff console's CSS and JS |
| `beatzlock_app/static/` | site-wide only: the favicons and the `fmb_theme` stylesheet the base templates load |
| `beatzlock_app/templates/` | site-wide base templates; per-app templates live in the app |
| `otp_backend/static/` | the API's favicon, used by its admin and log viewer |
| `otp_auth_app/inno_script/`, `otp_auth_app/vc_redist/` | Windows installer inputs, read by `otp_auth_app/build.py` |
| `otp_auth_app/build_logs/` | build metadata the console's build-history page reads |
| `beatzlock_app/release_notes/`, `beatzlock_app/tos_privacy/` | content published by the downloads site |

### Signing in

Both projects sign people in by **email address**. Neither asks for a username
anywhere: not on the sign-in page, not in the admin, not when the deploy script
creates the first superuser. `createsuperuser` is overridden in both to take an
email and nothing else, and it writes that address into Django's `username`
column too, so the two can never drift apart. Changing the address in the admin
moves the username with it.

Django's `username` column is NOT NULL and unique, so it cannot simply be
dropped — that would mean a custom user model and an `AUTH_USER_MODEL` swap
that a restore of an older dump would then fight with. Keeping it equal to the
email costs nothing and leaves every old dump restorable.

The API has accounts older than this rule whose username is not their email.
Nothing here rewrites them: `find_user_by_login_identifier` — in
`otp_backend/accounts/identity.py`, mirrored in
`beatzlock_app/beatzlock_app/identity.py` — resolves the email first and falls
back to the username, so those accounts keep signing in while everything
created from now on is email-only.

## Deploy

Each project deploys itself. Same script, same actions, same menu — one per
project, each reading only its own `.env` for its domain, ports and database
credentials, so nothing is prompted for and every step checks the current
state first. Both are safe to re-run.

```bash
sudo ./beatzlock_app/deploy/deploy.sh            # menu: pick the action
sudo ./beatzlock_app/deploy/deploy.sh --update   # or name it outright
sudo ./otp_backend/deploy/deploy.sh --status
```

| Action | What it does |
|---|---|
| `--fresh` | apt, PostgreSQL role + database, virtualenv, dependencies, migrate, collectstatic, superuser, systemd unit, nginx, firewall |
| `--update` | routine deploy: dependencies, migrate, collectstatic, re-render unit and nginx site, restart |
| `--restart` | restart gunicorn, reload nginx |
| `--status` | service, port, database, migrations, certificate, end-to-end request |
| `--logs` | gunicorn, nginx and Django logs |
| `--database` | create/repair, back up, restore, psql shell, reset |
| `--django …` | any `manage.py` command, e.g. `--django createsuperuser` |
| `--renew` | renew this subdomain's certificate |
| `--uninstall` | remove the unit and the nginx site; keeps code, database and `.env` |

Deploying both is two commands, in either order — they touch different
databases, different units and different nginx sites.

Each subdomain needs a DNS A record pointing at this server *before* its
first deploy: the certificate is issued over an HTTP-01 challenge, which can
only be answered for a name that already resolves here. The scripts check this
before calling certbot and print the exact record to create, because a failed
issuance still counts against the Let's Encrypt rate limit for the week.

`HTTP2=off` in a project's `.env` drops that site back to HTTP/1.1 over the
same TLS on the next deploy. It exists for one symptom: a large upload through
the admin that stalls and leaves the browser reporting
`ERR_HTTP2_PING_FAILED`, which happens when the HTTP/2 path between a client
and this host cannot carry a big request body. Everything else is unaffected —
the setting defaults to `on`, and `--status` prints which is in force.

TLS is not re-issued when an installed certificate already covers the
subdomain — a wildcard counts. Each project's `deploy/nginx.conf.template` and
`deploy/gunicorn.service.template` are the single source of truth for what
gets installed; edit the template, never the copy under `/etc/`. The files
under each project's `nginx/` are reference copies of what those templates
produce, kept for reading only.

## Moving the server to this layout

Two moves have happened since the server was last set up. The API used to live
at `/home/felixmokayabeatz/totp_app/` with its own ad-hoc `deploy.sh` and the
databases were named `beatzlock_app_db` and `beatzlock_db` under the role
`beatzlock_user`; more recently the downloads site moved out of the repo root
into `beatzlock_app/`. On the server, once:

**1. Move the checkout.** The repo root is now `beatzlock_project`, with each
project one directory below it:

```bash
cd /home/felixmokayabeatz
git clone <this repo> beatzlock_project      # or move the existing checkout
```

**2. Bring the downloads site's untracked files along.** `.env`, the
virtualenv, `logs/`, `media/`, `staticfiles/` and `backups/` are git-ignored,
so pulling the restructure leaves them behind at the repo root while the code
that reads them now lives in `beatzlock_app/`. Move them in — `media/`
especially, it holds every uploaded binary:

```bash
cd /home/felixmokayabeatz/beatzlock_project
for d in .env beatzlock_v_env logs media staticfiles backups; do
    [ -e "$d" ] && mv "$d" beatzlock_app/
done
```

The API's own copies of these were always inside `otp_backend/` and do not
move. Nothing under `otp_auth_app/` moves either.

**3. Rename the databases.** The deploy scripts create an *empty* database
when the name in `.env` does not exist — they will not carry the old rows
over. Rename first, then deploy:

```bash
sudo -u postgres psql -c 'ALTER DATABASE beatzlock_app_db RENAME TO felixmokayabeatz_totp_db;'
sudo -u postgres psql -c 'ALTER DATABASE beatzlock_db     RENAME TO felixmokayabeatz_beatzlock_db;'

# Hand both to the shared role the other sites already use.
sudo -u postgres psql -c 'ALTER DATABASE felixmokayabeatz_totp_db      OWNER TO "Felix_Apps_Administrator";'
sudo -u postgres psql -c 'ALTER DATABASE felixmokayabeatz_beatzlock_db OWNER TO "Felix_Apps_Administrator";'
sudo -u postgres psql -d felixmokayabeatz_totp_db      -c 'REASSIGN OWNED BY beatzlock_user TO "Felix_Apps_Administrator";'
sudo -u postgres psql -d felixmokayabeatz_beatzlock_db -c 'REASSIGN OWNED BY beatzlock_user TO "Felix_Apps_Administrator";'
```

A rename needs no other session on the database, so stop the old services
first. Take a dump before any of this:
`sudo -u postgres pg_dump -Fc beatzlock_app_db > totp.dump`.

**4. Retire the old units and sites.**

```bash
sudo systemctl disable --now beatzlock          # the old API unit
sudo rm /etc/nginx/sites-enabled/beatzlock
```

The new units are `beatzlock` (downloads site) and `beatzlock-api`. The old
API unit shared the name `beatzlock`, so remove it before deploying the site,
or the two will fight over it.

**5. Deploy both.** The rendered unit and nginx site carry the project
directory in them, so this run is also what repoints them at
`beatzlock_project/beatzlock_app/`:

```bash
sudo ./beatzlock_app/deploy/deploy.sh --fresh
sudo ./otp_backend/deploy/deploy.sh  --fresh
```

**6. Repoint the console's build-log path.** `BEATZLOCK_BUILD_LOGS_DIR` in
`beatzlock_app/.env` reads
`/home/felixmokayabeatz/beatzlock_project/otp_auth_app/build_logs`.

## Local development

Neither `.env` is committed. Copy the server's, or write your own from the
tables above.

**Downloads site:**

```bash
cd beatzlock_app
python -m venv beatzlock_v_env && . beatzlock_v_env/Scripts/activate   # Windows
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver 8005
```

**Authenticator API:**

```bash
cd otp_backend
python -m venv totp_v_env && . totp_v_env/Scripts/activate
pip install -r requirements.txt
python manage.py migrate
python manage.py runserver 8000
```

`beatzlock_app/config/local.py` and `otp_backend/otp_backend/local.py` are
git-ignored dev-only overrides, imported last so they win over everything —
which is why each `deploy.sh` refuses to run on a host where its project's one
exists. `otp_backend`'s currently just sets `DEBUG=True`.

Set `USE_X_ACCEL_REDIRECT=False` in the downloads site's `.env` for local work:
in production nginx streams app binaries via `X-Accel-Redirect` so no gunicorn
worker carries the payload (`beatzlock_app/beatzlock_app/utils/file_serving.py`),
and there is no nginx in front of `runserver`.

## The Flutter client

`otp_auth_app/` is self-contained: the Dart source, the Windows installer
inputs (`inno_script/`, `vc_redist/`), the build logs and every build output
live inside it. Nothing it produces is written outside that folder.

### Where its endpoints come from

Every URL the app calls is in `lib/config/app_config.dart`. Each environment is
built from one base string per server, so the halves cannot drift apart:

| | Authenticator API | Downloads site |
|---|---|---|
| Production | `https://api.felixmokayabeatz.online/api/` | `https://apps.felixmokayabeatz.online/` |
| Desktop dev | `http://localhost:8000/api/` | `http://localhost:8005/` |
| Android emulator dev | `http://10.0.2.2:8000/api/` | `http://10.0.2.2:8005/` |

`10.0.2.2` is the emulator's alias for the host machine's localhost, and the
dev ports are the two `runserver` ports from **Local development** above.
`AppConfig.isDevelopment` chooses between the columns — it must be `false` in
anything you ship.

The downloads site used to be mounted at `felixmokayabeatz.online/beatzlock-apps/`
and now sits at the root of its own subdomain. Everything the app reads from it
hangs off that single base URL:

| `AppConfig` member | Path | What answers it |
|---|---|---|
| `updateApiUrl` | `api/update-check/` | update check, including the release notes text |
| `legalDocumentApiUrl(type)` | `api/legal/<type>/` | terms / privacy as JSON |
| `legalDocumentWebUrl(type)` | `legal/terms-of-service/`, `legal/privacy-policy/` | the same documents as web pages |
| `ratingsApiUrl`, `myRatingApiUrl`, `ratingSubmitApiUrl`, `ratingDeleteApiUrl` | `api/ratings/…` | reviews |
| `rateAppUrl` | `rate/` | the review form |
| `manualDownloadUrl` | `downloads/` | the downloads page |

If in-app release notes, ratings or update checks stop working while the same
things still work in a browser, this file is the first place to look: the app
is talking to a host or a path the site no longer serves.

### The update check

```text
GET /api/update-check/?platform=<platform>&version=<version>&build_number=<n>
```

Add `&linux_distribution=<distro>` for Linux builds. The response carries
`update_available`, `force_update`, `latest_version`, `latest_build_number`,
`download_url`, `downloads_page_url`, `release_notes` and a human-readable
`reason`. An update is forced once a client is five or more releases or builds
behind. `download_url` and `downloads_page_url` are reversed from the site's
`urls.py`, never written out by hand, so remounting the site cannot hand the
app a dead link.

### Developing against the local servers

Three terminals — both Django projects, then the client:

```bash
cd beatzlock_app && python manage.py runserver 8005   # downloads site
cd otp_backend  && python manage.py runserver 8000    # authenticator API
cd otp_auth_app && flutter pub get && flutter run -d windows
```

Set `isDevelopment = true` in `lib/config/app_config.dart` first, and set it
back before building anything you intend to release. Use `-d linux`, `-d
android` or `-d windows` to pick the target; the platform sections below cover
each one in detail.

### Releasing a build

1. **Build.** `python3 build.py` from the repo root opens the menu. Artifacts
   land in `otp_auth_app/final_builds/<platform>/<version>/`, and the metadata
   for each one is appended to `otp_auth_app/build_logs/<platform>/build_log.json`.
2. **Publish.** In the downloads site admin, create the **App Release** first —
   version, build number and the release-notes `.txt`, which covers every
   platform — then add one **Platform Build** per binary pointing at it.
3. **Check the history.** `/console/build-history/` lists what was built from
   those `build_log.json` files, per platform and per day. It reads
   `otp_auth_app/build_logs/` next to the site by itself; set
   `BEATZLOCK_BUILD_LOGS_DIR` in the site's `.env` only if the Flutter checkout
   lives somewhere else entirely. A stale absolute path there is ignored, with
   a warning in the log, rather than leaving the page silently empty.
4. **Ship.** The next update check each client makes returns the new version,
   its notes and its download URL.

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

## Fedora Linux

Install the Fedora build tools and Flutter desktop dependencies:

```bash
sudo dnf install -y git curl unzip xz zip clang cmake gcc-c++ libstdc++-devel ninja-build pkgconf-pkg-config gtk3-devel libwebp-devel mesa-libGLU patchelf rpm-build rpmdevtools desktop-file-utils xdg-utils
```

If Flutter is not already installed, download the Linux SDK from the Flutter SDK archive, extract it, and add Flutter to your shell path:

```bash
mkdir -p "$HOME/develop"
tar -xf ~/Downloads/flutter_linux_*.tar.xz -C "$HOME/develop"
echo 'export PATH="$HOME/develop/flutter/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
flutter doctor -v
```

Install the app packages:

```bash
cd otp_auth_app
flutter pub get
```

Debug run on Fedora:

```bash
flutter run -d linux
```

Build the Fedora RPM from the repo root:

```bash
python3 build.py
```

`build.py` is a wrapper; the real script is `otp_auth_app/build.py` and every
path it reads or writes — `inno_script/`, `vc_redist/`, `final_builds/` and the
scratch package directories — sits inside `otp_auth_app/`.

Choose option `3. Fedora .rpm final build`, or option `1. Linux package for this distro (.deb/.rpm)` while on Fedora.

The RPM is written to:

```text
otp_auth_app/final_builds/fedora/<version_build>/beatzlock_<version_build>_x86_64.rpm
```

Install the generated RPM:

```bash
sudo dnf install ./otp_auth_app/final_builds/fedora/<version_build>/beatzlock_<version_build>_x86_64.rpm
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

## Quick start

Each project runs from its own folder:

```bash
cd beatzlock_app && python manage.py runserver 8005   # downloads site
cd otp_backend  && python manage.py runserver 8000    # authenticator API
cd otp_auth_app && flutter run -d windows             # or -d linux, -d android
```

Deployment is `sudo ./<project>/deploy/deploy.sh` — see **Deploy** above. Be
careful running it against the live server.
