#!/usr/bin/env bash
#
# Ubuntu deploy for the BeatzLock projects.
#
# Two Django projects live side by side in this repo. Each has its own .env,
# virtualenv, database, subdomain and systemd unit, and each is deployed
# independently:
#
#   --site   downloads & ratings   apps.felixmokayabeatz.online   ./
#   --api    authenticator API     api.felixmokayabeatz.online    ./otp_backend/
#
#   sudo ./deploy/deploy.sh                  # menu: pick the project, then the action
#   sudo ./deploy/deploy.sh --api --update   # or name both outright
#   sudo ./deploy/deploy.sh --all --update   # both projects in one run
#
# Everything a deploy needs -- domain, ports, database credentials -- is read
# out of that project's .env, so nothing is prompted for. Safe to re-run: every
# step checks the current state before changing it.
#
# TLS: an installed certificate that already covers the domain is used as it
# stands -- a wildcard counts. Only when nothing covers it does certbot issue
# one, which is the case for this subdomain: every site on this host has its
# own certificate.
#
# Actions:
#   fresh      apt, PostgreSQL role + database, virtualenv, dependencies,
#              migrate, collectstatic, superuser, systemd unit, nginx,
#              firewall. A bare server to a live site in one run.
#   update     routine deploy: dependencies, migrate, collectstatic, re-render
#              the unit and the nginx site, restart. Keeps the virtualenv and
#              the database.
#   restart    restart gunicorn, reload nginx. Nothing else is touched.
#   renew      renew this site's certificate now.
#   status     what is running, what is listening, when the certificate expires.
#   logs       gunicorn, nginx and Django logs.
#   database   create/repair, back up, restore, psql shell.
#   django     createsuperuser, shell, arbitrary manage.py command.
#   uninstall  stop and remove the service and the nginx site. Keeps the code,
#              the database and the .env.
#
# --all repeats an action against both projects. It is refused for the actions
# that are destructive or interactive -- database, django, uninstall -- because
# those must name the project they are aimed at.
#
set -Eeuo pipefail

# ---------------------------------------------------------------- settings --
# SERVICE_NAME, VENV_DIR, PROJECT_DIR and the rest are per-project and get set
# by select_component below; only the host-wide settings live here.
#
# Only used for the acme-challenge location in the nginx site, so that an
# HTTP-01 renewal of the existing certificate is not swallowed by the 301.
ACME_ROOT="${ACME_ROOT:-/var/www/certbot}"
# Set CERT_NAME to pin /etc/letsencrypt/live/<name>; empty means autodetect
# whichever installed certificate actually covers $SITE_DOMAIN.
CERT_NAME="${CERT_NAME:-}"
WORKERS="${WORKERS:-3}"
BACKUP_DIR_NAME="${BACKUP_DIR_NAME:-backups}"

MODE=""
COMPONENT_ARG=""
RETURN_TO_MENU=0
SKIP_APT=0
SKIP_DB=0
SKIP_SSL=0
FORCE_SSL=0
ASSUME_YES=0
MANAGE_ARGS=()
RESTORE_FILE=""

# ------------------------------------------------------------------ output --
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s%s%s\n' "$GREEN" "$*" "$RESET"; }
warn()  { printf '    %s%s%s\n' "$YELLOW" "$*" "$RESET"; }
bad()   { printf '    %s%s%s\n' "$RED" "$*" "$RESET"; }
die()   { printf '\n%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

trap 'die "failed at line $LINENO. Nothing further was changed."' ERR

# yes_no <prompt> -- honours --yes, and answers no when there is no terminal.
yes_no() {
    local prompt="$1" reply
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ -t 0 ] || return 1
    printf '    %s [y/N]: ' "$prompt"
    read -r reply || reply=""
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
    cat <<USAGE
Usage: sudo ./deploy/deploy.sh [project] [action] [options]

Project (omit to be asked):
  --site            Downloads & ratings site, apps.felixmokayabeatz.online
  --api             Authenticator API, api.felixmokayabeatz.online
  --all             Both, one after the other. Refused for actions 6, 7 and 9,
                    which must name the project they are aimed at.

Actions (omit to get the menu):
  1, --fresh        Full install. apt packages, PostgreSQL role and database,
                    the virtualenv, dependencies, migrate, collectstatic,
                    superuser, systemd unit, nginx, firewall.
  2, --update       Routine deploy. Dependencies, migrate, collectstatic,
                    re-render the unit and the nginx site, restart.
  3, --restart      Restart gunicorn and reload nginx only.
  4, --status       Service, port, database and certificate health.
  5, --logs         Gunicorn, nginx and Django logs.
  6, --database     Database submenu: create/repair, backup, restore, psql, reset.
  7, --django ...   Run a manage.py command, e.g. --django createsuperuser.
  8, --renew        Renew this site's certificate now.
  9, --uninstall    Remove the service and the nginx site (keeps code and data).

Options:
  --skip-apt        Do not touch apt.
  --skip-db         Do not provision PostgreSQL.
  --skip-ssl        Do not run certbot.
  --force-ssl       Re-issue the certificate even when one already covers it.
  --restore FILE    With --database: restore that dump instead of the menu.
  -y, --yes         Assume yes at every confirmation.
  -h, --help        Show this message.

Environment overrides:
  SITE_SERVICE_NAME (default: beatzlock)      systemd unit, downloads site
  API_SERVICE_NAME (default: beatzlock-api)   systemd unit, API
  SITE_VENV_DIR (default: beatzlock_v_env)    virtualenv dir, downloads site
  API_VENV_DIR (default: totp_v_env)          virtualenv dir, API
  WORKERS (default: 3)                        gunicorn worker count
  CERT_NAME (default: autodetect)             /etc/letsencrypt/live/<name> to use
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --site)        COMPONENT_ARG="site" ;;
        --api)         COMPONENT_ARG="api" ;;
        --all|--both)  COMPONENT_ARG="all" ;;
        1|--fresh)     MODE="fresh" ;;
        2|--update)    MODE="update" ;;
        3|--restart)   MODE="restart" ;;
        4|--status)    MODE="status" ;;
        5|--logs)      MODE="logs" ;;
        6|--database)  MODE="database" ;;
        7|--django)    MODE="django"; shift; MANAGE_ARGS=("$@"); break ;;
        8|--renew)     MODE="renew" ;;
        9|--uninstall) MODE="uninstall" ;;
        --skip-apt)    SKIP_APT=1 ;;
        --skip-db)     SKIP_DB=1 ;;
        --skip-ssl)    SKIP_SSL=1 ;;
        --force-ssl)   FORCE_SSL=1 ;;
        --restore)     shift; [ $# -gt 0 ] || die "--restore needs a file."; RESTORE_FILE="$1" ;;
        -y|--yes)      ASSUME_YES=1 ;;
        -h|--help)     usage; exit 0 ;;
        *)             usage; die "unknown option: $1" ;;
    esac
    shift
done

# --------------------------------------------------------------- preflight --
step "Preflight"

[ "$(id -u)" -eq 0 ] || die "run this with sudo -- it writes to /etc and manages services."
command -v apt-get >/dev/null 2>&1 || die "this script targets Ubuntu/Debian (no apt-get found)."
command -v systemctl >/dev/null 2>&1 || die "systemd is required."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Run migrations and own the files as whoever owns the checkout, not as root,
# so the app never finds root-owned files it cannot rewrite.
RUN_USER="$(stat -c '%U' "$REPO_DIR")"
RUN_GROUP="$(stat -c '%G' "$REPO_DIR")"
[ "$RUN_USER" != "root" ] || warn "the checkout is owned by root; gunicorn will run as root."

info "repo       $REPO_DIR"
info "run as     $RUN_USER:$RUN_GROUP"

# ---------------------------------------------------------------- projects --
# The two Django projects in this repo. Everything past this point works on
# whichever one select_component last picked, so each action is written once
# and runs against either.
COMPONENTS=(site api)
COMPONENT=""

component_label() {
    case "$1" in
        site) printf 'downloads site' ;;
        api)  printf 'authenticator API' ;;
        *)    printf '%s' "$1" ;;
    esac
}

select_component() {
    COMPONENT="$1"
    case "$COMPONENT" in
        site)
            SERVICE_NAME="${SITE_SERVICE_NAME:-beatzlock}"
            # Matches the *_v_env entry in .gitignore, so the production
            # virtualenv has the same directory name as the local one and
            # neither is ever committed.
            VENV_DIR="${SITE_VENV_DIR:-beatzlock_v_env}"
            PROJECT_DIR="$REPO_DIR"
            WSGI_APP="config.wsgi:application"
            DESCRIPTION="Gunicorn for the BeatzLock downloads site"
            LOCAL_PY="$PROJECT_DIR/config/local.py"
            NGINX_TEMPLATE="$SCRIPT_DIR/nginx.site.conf.template"
            DB_NAME_DEFAULT="felixmokayabeatz_beatzlock_db"
            GUNICORN_PORT_DEFAULT="8012"
            ADMIN_PATH="/beatzlock-admin/"
            ;;
        api)
            SERVICE_NAME="${API_SERVICE_NAME:-beatzlock-api}"
            VENV_DIR="${API_VENV_DIR:-totp_v_env}"
            PROJECT_DIR="$REPO_DIR/otp_backend"
            WSGI_APP="otp_backend.wsgi:application"
            DESCRIPTION="Gunicorn for the BeatzLock authenticator API"
            LOCAL_PY="$PROJECT_DIR/otp_backend/local.py"
            NGINX_TEMPLATE="$SCRIPT_DIR/nginx.api.conf.template"
            DB_NAME_DEFAULT="felixmokayabeatz_totp_db"
            GUNICORN_PORT_DEFAULT="8002"
            ADMIN_PATH="/beatzlock_admin/"
            ;;
        *) die "unknown project: $COMPONENT (expected site or api)" ;;
    esac

    ENV_FILE="$PROJECT_DIR/.env"
    VENV_PATH="$PROJECT_DIR/$VENV_DIR"
    REQUIREMENTS_FILE="$PROJECT_DIR/requirements.txt"
    BACKUP_DIR="$PROJECT_DIR/$BACKUP_DIR_NAME"

    [ -f "$PROJECT_DIR/manage.py" ] || die "manage.py not found in $PROJECT_DIR."
    [ -f "$REQUIREMENTS_FILE" ] || die "requirements.txt not found at $REQUIREMENTS_FILE."
    [ -f "$ENV_FILE" ] || die ".env not found at $ENV_FILE -- it supplies the domain, the ports and the database credentials."

    # local.py is what marks a checkout as local development, and it has the
    # last word over every setting, DEBUG included. It is git-ignored and
    # belongs on a developer machine only; on a server it would quietly serve
    # the whole thing with DEBUG=True.
    [ ! -f "$LOCAL_PY" ] \
        || die "${LOCAL_PY#$REPO_DIR/} exists on this host. It marks a local dev checkout and overrides production settings including DEBUG. Delete it and re-run."

    info "project    .${PROJECT_DIR#$REPO_DIR}/  ($(component_label "$COMPONENT"))"
}

as_run_user() { sudo -u "$RUN_USER" "$@"; }
manage() { sudo -u "$RUN_USER" "$VENV_PATH/bin/python" "$PROJECT_DIR/manage.py" "$@"; }

require_venv() {
    [ -x "$VENV_PATH/bin/python" ] \
        || die "no virtualenv at $VENV_PATH. Run action 1 (fresh install) first."
}

# ------------------------------------------------------------------ config --
# Pull one key out of .env without sourcing it -- values may contain spaces,
# '#', or quotes that a `source` would mangle or execute.
env_get() {
    local key="$1" line value
    line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$ENV_FILE" | tail -n 1 || true)"
    if [ -z "$line" ]; then printf ''; return 0; fi
    value="${line#*=}"
    # A .env authored on Windows arrives with CRLF; a trailing CR would end up
    # inside the domain, the port and the database password.
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

read_config() {
    step "Reading ${ENV_FILE#$REPO_DIR/}"

    DOMAIN="$(env_get SITE_DOMAIN)"
    [ -n "$DOMAIN" ] || die "SITE_DOMAIN is not set in .env -- that is the subdomain to deploy and certify."

    GUNICORN_PORT="$(env_get GUNICORN_PORT)"
    GUNICORN_PORT="${GUNICORN_PORT:-$GUNICORN_PORT_DEFAULT}"

    DB_URL="$(env_get DATABASE_URL)"
    DB_NAME="$(env_get DJANGO_DB_NAME)"; DB_NAME="${DB_NAME:-$DB_NAME_DEFAULT}"
    DB_USER="$(env_get DJANGO_DB_USER)"
    DB_PASS="$(env_get DJANGO_DB_PASSWORD)"
    DB_HOST="$(env_get DJANGO_DB_HOST)"; DB_HOST="${DB_HOST:-localhost}"
    DB_PORT="$(env_get DJANGO_DB_PORT)"; DB_PORT="${DB_PORT:-5432}"
    TZ_NAME="$(env_get TIME_ZONE)"; TZ_NAME="${TZ_NAME:-UTC}"

    NGINX_AVAILABLE="/etc/nginx/sites-available/$DOMAIN"
    NGINX_ENABLED="/etc/nginx/sites-enabled/$DOMAIN"
    UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

    # Optional: only read when certbot has to register a new ACME account.
    SSL_EMAIL="$(bare_email "$(env_get CERTBOT_EMAIL)")"
    local _key
    for _key in ADMIN_EMAIL SUPPORT_EMAIL DEFAULT_FROM_EMAIL; do
        [ -n "$SSL_EMAIL" ] && break
        SSL_EMAIL="$(bare_email "$(env_get "$_key")")"
    done

    ok "domain     $DOMAIN"
    ok "gunicorn   127.0.0.1:$GUNICORN_PORT"
    ok "database   $DB_NAME@$DB_HOST:$DB_PORT"

    resolve_certificate
}

# An address may be written as "Felix Mokaya <no-reply@example.com>"; certbot
# wants the bare address.
bare_email() {
    local raw="$1"
    case "$raw" in *"<"*">"*) raw="${raw#*<}"; raw="${raw%%>*}" ;; esac
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    printf '%s' "$raw"
}

# --------------------------------------------------------------------- tls --
# Nothing here issues anything. The certificate already exists; these just
# find it and prove it really covers this subdomain, because serving a
# certificate that does not name $DOMAIN is a browser-blocking error.

# cert_names <fullchain.pem> -- every DNS name on the certificate.
cert_names() {
    openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
        | tr -d ' ' | tr ',' '\n' | sed -n 's/^DNS://p'
}

# cert_covers <fullchain.pem> <name> -- exact match, or a wildcard one label up.
cert_covers() {
    local pem="$1" name="$2" san parent
    parent="${name#*.}"
    while IFS= read -r san; do
        [ -z "$san" ] && continue
        [ "$san" = "$name" ] && return 0
        [ "$san" = "*.$parent" ] && [ "$name" != "$parent" ] && return 0
    done < <(cert_names "$pem")
    return 1
}

# Sets CERT_DIR and SERVER_NAMES. A missing certificate is not fatal here --
# install_nginx_site is where it matters, and it says so there.
resolve_certificate() {
    CERT_DIR=""
    SERVER_NAMES="$DOMAIN"

    if [ -n "$CERT_NAME" ]; then
        CERT_DIR="/etc/letsencrypt/live/$CERT_NAME"
        [ -f "$CERT_DIR/fullchain.pem" ] \
            || die "CERT_NAME=$CERT_NAME but there is no $CERT_DIR/fullchain.pem."
        cert_covers "$CERT_DIR/fullchain.pem" "$DOMAIN" \
            || die "the certificate at $CERT_DIR does not cover $DOMAIN. It names: $(cert_names "$CERT_DIR/fullchain.pem" | tr '\n' ' ')"
    else
        # Two passes: a certificate that names this subdomain outright beats a
        # wildcard, so the site keeps working if the wildcard is ever retired.
        local dir
        for dir in /etc/letsencrypt/live/*/; do
            [ -f "$dir/fullchain.pem" ] || continue
            if cert_names "$dir/fullchain.pem" | grep -qxF "$DOMAIN"; then
                CERT_DIR="${dir%/}"
                break
            fi
        done
        if [ -z "$CERT_DIR" ]; then
            for dir in /etc/letsencrypt/live/*/; do
                [ -f "$dir/fullchain.pem" ] || continue
                if cert_covers "$dir/fullchain.pem" "$DOMAIN"; then
                    CERT_DIR="${dir%/}"
                    break
                fi
            done
        fi
    fi

    if [ -z "$CERT_DIR" ]; then
        warn "no installed certificate covers $DOMAIN"
        return 0
    fi

    # Serve www. from this vhost only when the same certificate covers it;
    # otherwise nginx would answer www. with a certificate for another name.
    if cert_covers "$CERT_DIR/fullchain.pem" "www.$DOMAIN"; then
        SERVER_NAMES="$DOMAIN www.$DOMAIN"
    fi
    ok "certificate $(basename "$CERT_DIR")  [$SERVER_NAMES]"
}

# Names to put on a new certificate: the domain, plus www. when it resolves --
# certbot fails the whole request if any one name has no DNS record.
cert_domain_args() {
    CERT_DOMAIN_ARGS=(-d "$DOMAIN")
    if getent hosts "www.$DOMAIN" >/dev/null 2>&1; then
        CERT_DOMAIN_ARGS+=(-d "www.$DOMAIN")
    fi
}

# Certbot only wants an address when it has to register a *new* ACME account.
# This host already has one from the sibling sites, so a missing address is
# never fatal -- it only costs the expiry warning mail.
acme_account_exists() {
    [ -d /etc/letsencrypt/accounts ] || return 1
    [ -n "$(find /etc/letsencrypt/accounts -name regr.json -print -quit 2>/dev/null)" ]
}

CERTBOT_ACCOUNT_ARGS=()
resolve_certbot_account() {
    CERTBOT_ACCOUNT_ARGS=()
    case "$SSL_EMAIL" in
        *@*.*)
            CERTBOT_ACCOUNT_ARGS=(--email "$SSL_EMAIL")
            info "expiry warnings go to $SSL_EMAIL"
            return 0
            ;;
    esac
    if acme_account_exists; then
        # certbot reuses the account on disk; --email is only read at
        # registration, so there is nothing to pass.
        info "no address in .env; reusing the ACME account already on this host"
    else
        CERTBOT_ACCOUNT_ARGS=(--register-unsafely-without-email)
        warn "no address in .env and no ACME account on this host -- registering without one."
    fi
}

# The real site config references the certificate, so nginx cannot load it until
# the certificate exists. Serve a bare HTTP site first, just enough to answer
# the ACME challenge, then swap in the real config once the cert is on disk.
install_bootstrap_site() {
    cat > "$NGINX_AVAILABLE" <<BOOTSTRAP
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    location /.well-known/acme-challenge/ {
        root $ACME_ROOT;
    }

    location / {
        return 503;
    }
}
BOOTSTRAP
    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    [ -e /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default
    nginx -t >/dev/null 2>&1 || die "the bootstrap nginx config failed to validate."
    systemctl reload nginx 2>/dev/null || systemctl start nginx
}

obtain_certificate() {
    if [ "$SKIP_SSL" -eq 1 ]; then info "certbot skipped (--skip-ssl)"; return 0; fi

    # Autodetection already found one that covers the domain; nothing to do.
    if [ -n "$CERT_DIR" ] && [ "$FORCE_SSL" -eq 0 ]; then
        return 0
    fi

    step "Obtaining the TLS certificate"
    command -v certbot >/dev/null 2>&1 \
        || die "certbot is not installed. Run action 1 without --skip-apt, or install it yourself."

    cert_domain_args
    if [ "${#CERT_DOMAIN_ARGS[@]}" -gt 2 ]; then
        info "www.$DOMAIN resolves; including it on the certificate."
    else
        info "www.$DOMAIN does not resolve; certifying $DOMAIN only."
    fi

    mkdir -p "$ACME_ROOT"
    chown -R www-data:www-data "$ACME_ROOT" 2>/dev/null || true
    install_bootstrap_site
    info "serving the ACME challenge from $ACME_ROOT"
    resolve_certbot_account

    # --webroot rather than --nginx: certbot only writes the challenge file and
    # never edits the site config, so the template stays the single source of
    # truth for what nginx serves.
    certbot certonly \
        --webroot -w "$ACME_ROOT" \
        "${CERT_DOMAIN_ARGS[@]}" \
        --non-interactive \
        --agree-tos \
        "${CERTBOT_ACCOUNT_ARGS[@]}" \
        --keep-until-expiring \
        --no-eff-email \
        || die "certbot failed. Check that DNS for $DOMAIN points at this server and that port 80 is open."

    # Pick up the lineage certbot just wrote, and recompute SERVER_NAMES from
    # what it actually issued.
    resolve_certificate
    [ -n "$CERT_DIR" ] || die "certbot reported success but no certificate covering $DOMAIN was found."
    ok "certificate issued"
}

install_renewal_hook() {
    step "Certificate renewal"

    # Reload nginx after any future renewal, so a fresh cert is actually served.
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

    if systemctl list-unit-files | grep -q '^certbot.timer'; then
        systemctl enable --now certbot.timer >/dev/null 2>&1 || true
        ok "certbot.timer active; nginx reloads automatically on renewal"
    else
        warn "certbot.timer not found -- add a cron entry for 'certbot renew' yourself."
    fi
}

renew_certificate() {
    step "Renewing the certificate"
    [ -n "$CERT_DIR" ] || die "no certificate covering $DOMAIN to renew. Run action 1."
    certbot renew --cert-name "$(basename "$CERT_DIR")" --webroot -w "$ACME_ROOT" \
        --no-random-sleep-on-renew
    reload_nginx
    if [ -f "$CERT_DIR/fullchain.pem" ]; then
        ok "valid until $(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" | cut -d= -f2)"
    fi
}

# ---------------------------------------------------------------- apt deps --
do_apt() {
    if [ "$SKIP_APT" -eq 1 ]; then info "apt skipped (--skip-apt)"; return 0; fi
    step "Installing system packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq \
        python3 python3-venv python3-dev build-essential \
        postgresql postgresql-contrib libpq-dev postgresql-client \
        nginx certbot python3-certbot-nginx \
        git curl openssl >/dev/null
    ok "packages present"
}

# -------------------------------------------------------------- secret key --
# A missing SECRET_KEY fails at import time, so generate one rather than let
# the first migrate blow up. Alphanumeric only: the value goes through sed.
ensure_secret_key() {
    local key
    key="$(env_get DJANGO_SECRET_KEY)"
    [ -n "$key" ] && return 0

    step "Django secret key"
    key="$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(64)))")"
    if grep -qE '^[[:space:]]*DJANGO_SECRET_KEY[[:space:]]*=' "$ENV_FILE"; then
        sed -i "s|^[[:space:]]*DJANGO_SECRET_KEY[[:space:]]*=.*|DJANGO_SECRET_KEY=$key|" "$ENV_FILE"
    else
        printf '\nDJANGO_SECRET_KEY=%s\n' "$key" >> "$ENV_FILE"
    fi
    chown "$RUN_USER:$RUN_GROUP" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "generated a DJANGO_SECRET_KEY and wrote it to .env"
    warn "any existing sessions and password-reset links are invalidated by this."
}

# -------------------------------------------------------------- postgresql --
sql_lit()    { printf '%s' "${1//\'/\'\'}"; }   # quote a value for SQL
psql_su()    { sudo -u postgres psql -v ON_ERROR_STOP=1 -Atqc "$1"; }
psql_su_db() { sudo -u postgres psql -v ON_ERROR_STOP=1 -Atq -d "$1" -c "$2"; }

# Names go into SQL as double-quoted identifiers; refuse anything that would
# need escaping rather than trying to escape it.
valid_identifier() {
    case "$1" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
        [0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# Is the database ours to create -- i.e. PostgreSQL on this same machine?
database_is_local() {
    [ -n "$DB_URL" ] && return 1
    case "$DB_HOST" in
        ""|localhost|127.0.0.1|::1) return 0 ;;
        *) return 1 ;;
    esac
}

provision_database() {
    step "PostgreSQL"

    if [ "$SKIP_DB" -eq 1 ]; then info "database skipped (--skip-db)"; return 0; fi
    if [ -n "$DB_URL" ]; then
        info "DATABASE_URL is set in .env; that connection is managed elsewhere."
        return 0
    fi
    if ! database_is_local; then
        info "DJANGO_DB_HOST is $DB_HOST -- not this machine, nothing to provision."
        return 0
    fi

    [ -n "$DB_USER" ] || die "DJANGO_DB_USER is empty in .env."
    [ -n "$DB_PASS" ] || die "DJANGO_DB_PASSWORD is empty in .env."
    valid_identifier "$DB_NAME" || die "DJANGO_DB_NAME '$DB_NAME' is not a plain identifier."
    valid_identifier "$DB_USER" || die "DJANGO_DB_USER '$DB_USER' is not a plain identifier."

    command -v psql >/dev/null 2>&1 \
        || die "psql not found. Run action 1 without --skip-apt, or install postgresql yourself."

    if ! systemctl is-active --quiet postgresql; then
        info "starting postgresql"
        systemctl start postgresql
    fi
    systemctl enable postgresql >/dev/null 2>&1 || true

    local esc_user esc_name esc_pass esc_tz
    esc_user="$(sql_lit "$DB_USER")"
    esc_name="$(sql_lit "$DB_NAME")"
    esc_pass="$(sql_lit "$DB_PASS")"
    esc_tz="$(sql_lit "$TZ_NAME")"

    # The role may be shared with the other felixmokayabeatz sites on this
    # host, so an existing one is left exactly as it is -- its password and
    # its role-wide settings belong to whoever created it, not to this deploy.
    local role_created=0
    if [ "$(psql_su "SELECT 1 FROM pg_roles WHERE rolname = '$esc_user'")" = "1" ]; then
        ok "role $DB_USER already exists; leaving its password and settings alone"
    else
        psql_su "CREATE ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$esc_pass'" >/dev/null
        role_created=1
        # CREATEDB is for the test runner; the rest are the per-connection
        # settings Django would otherwise have to send every time. Only ever
        # applied to a role this script just created.
        psql_su "ALTER ROLE \"$DB_USER\" CREATEDB" >/dev/null
        psql_su "ALTER ROLE \"$DB_USER\" SET client_encoding TO 'utf8'" >/dev/null
        psql_su "ALTER ROLE \"$DB_USER\" SET default_transaction_isolation TO 'read committed'" >/dev/null
        psql_su "ALTER ROLE \"$DB_USER\" SET timezone TO '$esc_tz'" >/dev/null
        ok "created role $DB_USER"
    fi

    if [ "$(psql_su "SELECT 1 FROM pg_database WHERE datname = '$esc_name'")" = "1" ]; then
        ok "database $DB_NAME present"
    else
        psql_su "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\" ENCODING 'UTF8'" >/dev/null
        ok "created database $DB_NAME"
    fi

    psql_su "ALTER DATABASE \"$DB_NAME\" OWNER TO \"$DB_USER\"" >/dev/null
    psql_su "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\"" >/dev/null
    # PostgreSQL 15+ revoked CREATE on schema public from everyone; without
    # these the first migrate fails with "permission denied for schema public".
    psql_su_db "$DB_NAME" "GRANT ALL ON SCHEMA public TO \"$DB_USER\"" >/dev/null
    psql_su_db "$DB_NAME" "ALTER SCHEMA public OWNER TO \"$DB_USER\"" >/dev/null

    # Prove the credentials in .env work over TCP, which is how Django will
    # connect -- peer auth as postgres proves nothing about that.
    if db_login_works; then
        ok "connected as $DB_USER over TCP"
        return 0
    fi

    [ "$role_created" -eq 0 ] \
        || die "created $DB_USER but cannot log in as it at $DB_HOST:$DB_PORT. Check that pg_hba.conf allows md5/scram for local TCP connections."

    warn "the password in .env does not authenticate $DB_USER."
    warn "that role is shared with the other sites on this host -- changing its"
    warn "password changes it for all of them, and they will fail until their"
    warn "own .env files are updated to match."
    if yes_no "Set $DB_USER's password to the value in .env anyway?"; then
        psql_su "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$esc_pass'" >/dev/null
        db_login_works || die "still cannot log in as $DB_USER. Check that pg_hba.conf allows md5/scram for local TCP connections."
        ok "password reset; connected as $DB_USER over TCP"
    else
        die "cannot connect as $DB_USER to $DB_NAME at $DB_HOST:$DB_PORT. Fix DJANGO_DB_PASSWORD in .env and re-run."
    fi
}

db_login_works() {
    PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -Atqc 'SELECT 1' >/dev/null 2>&1
}

# -------------------------------------------------------------- virtualenv --
build_venv() {
    local reset="${1:-0}"
    step "Python environment"

    if [ "$reset" -eq 1 ] && [ -d "$VENV_PATH" ]; then
        # Stop the service first: deleting the interpreter out from under a
        # running gunicorn leaves it in a confusing half-dead state.
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            info "stopping $SERVICE_NAME before rebuilding the virtualenv"
            systemctl stop "$SERVICE_NAME"
        fi
        info "removing $VENV_PATH"
        rm -rf "$VENV_PATH"
    fi

    if [ ! -x "$VENV_PATH/bin/python" ]; then
        info "creating $VENV_PATH"
        as_run_user python3 -m venv "$VENV_PATH"
    fi

    as_run_user "$VENV_PATH/bin/pip" install --quiet --upgrade pip wheel
    as_run_user "$VENV_PATH/bin/pip" install --quiet -r "$REQUIREMENTS_FILE"
    ok "dependencies installed into $VENV_DIR"
}

# ------------------------------------------------------------------ django --
run_django_steps() {
    step "Django checks"
    manage check --deploy --fail-level ERROR
    ok "system checks passed"

    step "Migrating the database"
    manage migrate --noinput
    ok "migrations applied"

    step "Collecting static files"
    # --clear matters with the hashed manifest: without it, replaced assets
    # leave their old hashed copies behind in staticfiles/ forever.
    manage collectstatic --noinput --clear >/dev/null
    ok "static files collected into $PROJECT_DIR/staticfiles"

    # nginx serves staticfiles/ and media/ straight off disk, so www-data has
    # to be able to read into them. logs/ is written by the app itself.
    local d
    for d in staticfiles media logs; do
        [ -d "$PROJECT_DIR/$d" ] || as_run_user mkdir -p "$PROJECT_DIR/$d"
        chown -R "$RUN_USER:$RUN_GROUP" "$PROJECT_DIR/$d"
    done
    for d in staticfiles media; do
        chgrp -R www-data "$PROJECT_DIR/$d" 2>/dev/null || true
        chmod -R g+rX "$PROJECT_DIR/$d" 2>/dev/null || true
    done
    chown "$RUN_USER:$RUN_GROUP" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

ensure_superuser() {
    step "Django superuser"
    local exists
    exists="$(manage shell -c 'from django.contrib.auth import get_user_model; print(get_user_model().objects.filter(is_superuser=True).exists())' 2>/dev/null | tail -n 1 || true)"

    if [ "$exists" = "True" ]; then
        info "a superuser already exists; leaving it alone"
        return 0
    fi
    if [ ! -t 0 ]; then
        warn "no terminal attached; skipping. Create one later with:"
        warn "  sudo ./deploy/deploy.sh --django createsuperuser"
        return 0
    fi
    info "no superuser found -- creating one for https://$DOMAIN$ADMIN_PATH"
    if manage createsuperuser; then
        ok "superuser created"
    else
        warn "createsuperuser did not complete; run --django createsuperuser later."
    fi
}

# -------------------------------------------------------------- templating --
render() {
    # render <template> <destination>; returns 0 if the file changed.
    local src="$1" dest="$2" tmp
    tmp="$(mktemp)"
    sed \
        -e "s|__DOMAIN__|$DOMAIN|g" \
        -e "s|__SERVER_NAMES__|$SERVER_NAMES|g" \
        -e "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
        -e "s|__GUNICORN_PORT__|$GUNICORN_PORT|g" \
        -e "s|__ACME_ROOT__|$ACME_ROOT|g" \
        -e "s|__CERT_DIR__|$CERT_DIR|g" \
        -e "s|__SERVICE_NAME__|$SERVICE_NAME|g" \
        -e "s|__RUN_USER__|$RUN_USER|g" \
        -e "s|__RUN_GROUP__|$RUN_GROUP|g" \
        -e "s|__VENV_DIR__|$VENV_DIR|g" \
        -e "s|__WORKERS__|$WORKERS|g" \
        -e "s|__WSGI_APP__|$WSGI_APP|g" \
        -e "s|__DESCRIPTION__|$DESCRIPTION|g" \
        "$src" > "$tmp"
    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$dest"
    chmod 0644 "$dest"
    return 0
}

# ---------------------------------------------------------------- gunicorn --
install_unit() {
    step "Gunicorn service"
    if render "$SCRIPT_DIR/gunicorn.service.template" "$UNIT_PATH"; then
        info "wrote $UNIT_PATH"
        systemctl daemon-reload
    else
        info "$UNIT_PATH already current"
    fi
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
}

restart_service() {
    [ -f "$UNIT_PATH" ] \
        || die "$UNIT_PATH does not exist. Run action 1 or 2 to install it first."
    step "Restarting $SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl is-active --quiet "$SERVICE_NAME" \
        || die "$SERVICE_NAME did not start. Inspect: journalctl -u $SERVICE_NAME -n 50 --no-pager"
    ok "$SERVICE_NAME running on 127.0.0.1:$GUNICORN_PORT"
}

# ------------------------------------------------------------- ssl options --
ensure_ssl_options() {
    # The site config includes both of these. They normally arrive with
    # certbot's nginx installer; write them if this host has not got them.
    if [ ! -f /etc/letsencrypt/options-ssl-nginx.conf ]; then
        info "writing /etc/letsencrypt/options-ssl-nginx.conf"
        cat > /etc/letsencrypt/options-ssl-nginx.conf <<'SSLOPTS'
ssl_session_cache shared:le_nginx_SSL:10m;
ssl_session_timeout 1440m;
ssl_session_tickets off;

ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;

ssl_ciphers "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384";
SSLOPTS
    fi
    if [ ! -f /etc/letsencrypt/ssl-dhparams.pem ]; then
        info "generating /etc/letsencrypt/ssl-dhparams.pem (this takes a moment)"
        openssl dhparam -out /etc/letsencrypt/ssl-dhparams.pem 2048 2>/dev/null
    fi
}

# ------------------------------------------------------------------- nginx --
install_nginx_site() {
    step "Nginx site"

    if [ -z "$CERT_DIR" ]; then
        bad "no installed certificate covers $DOMAIN, so the site cannot be served."
        info "certificates on this host:"
        local d
        for d in /etc/letsencrypt/live/*/; do
            [ -f "$d/fullchain.pem" ] || continue
            info "  $(basename "$d")  ->  $(cert_names "$d/fullchain.pem" | tr '\n' ' ')"
        done
        die "certbot did not produce a certificate for $DOMAIN. Re-run without --skip-ssl, or point this script at an existing one with CERT_NAME=<name>."
    fi
    ensure_ssl_options

    local backup=""
    if [ -f "$NGINX_AVAILABLE" ]; then
        backup="$(mktemp)"
        cp "$NGINX_AVAILABLE" "$backup"
    fi

    if render "$NGINX_TEMPLATE" "$NGINX_AVAILABLE"; then
        info "wrote $NGINX_AVAILABLE"
    else
        info "$NGINX_AVAILABLE already current"
    fi
    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    [ -e /etc/nginx/sites-enabled/default ] && rm -f /etc/nginx/sites-enabled/default

    if ! nginx -t >/dev/null 2>&1; then
        if [ -n "$backup" ]; then
            cp "$backup" "$NGINX_AVAILABLE"
            warn "restored the previous config"
        fi
        nginx -t || true
        die "the rendered nginx config failed validation; nothing was reloaded."
    fi
    [ -n "$backup" ] && rm -f "$backup"
    systemctl enable nginx >/dev/null 2>&1 || true
}

reload_nginx() {
    step "Reloading nginx"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl start nginx
        ok "nginx reloaded"
    else
        nginx -t || true
        die "nginx config is invalid; it was left running on the previous config."
    fi
}

# ---------------------------------------------------------------- firewall --
configure_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    if ! ufw status 2>/dev/null | grep -q '^Status: active'; then
        info "ufw is installed but inactive; leaving it that way"
        return 0
    fi
    step "Firewall"
    # Gunicorn binds 127.0.0.1 only, so it needs no rule of its own.
    ufw allow 'Nginx Full' >/dev/null 2>&1 || true
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ok "ufw allows OpenSSH and Nginx Full (80/443)"
}

# ------------------------------------------------------------------ status --
show_status() {
    step "Status"

    printf '    %-14s %s\n' "project" "$PROJECT_DIR"
    if [ -x "$VENV_PATH/bin/python" ]; then
        printf '    %-14s %s (%s)\n' "virtualenv" "$VENV_DIR" "$("$VENV_PATH/bin/python" -V 2>&1)"
    else
        printf '    %-14s %s\n' "virtualenv" "MISSING at $VENV_PATH"
    fi

    local state
    if [ -f "$UNIT_PATH" ]; then
        state="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
        if [ "$state" = "active" ]; then
            ok "$SERVICE_NAME  active since $(systemctl show -p ActiveEnterTimestamp --value "$SERVICE_NAME")"
        else
            bad "$SERVICE_NAME  $state  (journalctl -u $SERVICE_NAME -n 50)"
        fi
    else
        bad "$SERVICE_NAME  no unit installed"
    fi

    state="$(systemctl is-active nginx 2>/dev/null || true)"
    if [ "$state" = "active" ]; then ok "nginx        active"; else bad "nginx        $state"; fi

    state="$(systemctl is-active postgresql 2>/dev/null || true)"
    if [ "$state" = "active" ]; then ok "postgresql   active"; else warn "postgresql   $state"; fi

    if command -v ss >/dev/null 2>&1; then
        if ss -ltn 2>/dev/null | grep -q ":$GUNICORN_PORT[[:space:]]"; then
            ok "port $GUNICORN_PORT   listening"
        else
            bad "port $GUNICORN_PORT   nothing listening"
        fi
    fi

    if [ -x "$VENV_PATH/bin/python" ]; then
        if manage check --database default >/dev/null 2>&1; then
            ok "database     reachable ($DB_NAME)"
        else
            bad "database     unreachable ($DB_NAME@$DB_HOST:$DB_PORT)"
        fi
        local pending
        pending="$(manage showmigrations --plan 2>/dev/null | grep -c '^\[ \]' || true)"
        if [ "${pending:-0}" -gt 0 ]; then
            warn "migrations   $pending unapplied"
        else
            ok "migrations   up to date"
        fi
    fi

    if [ -n "$CERT_DIR" ] && [ -f "$CERT_DIR/fullchain.pem" ]; then
        local enddate
        enddate="$(openssl x509 -enddate -noout -in "$CERT_DIR/fullchain.pem" 2>/dev/null | cut -d= -f2)"
        if openssl x509 -checkend $((21 * 86400)) -noout -in "$CERT_DIR/fullchain.pem" >/dev/null 2>&1; then
            ok "certificate  $(basename "$CERT_DIR") valid until $enddate"
        else
            warn "certificate  $(basename "$CERT_DIR") expires soon: $enddate  (renewed wherever it was issued)"
        fi
    else
        bad "certificate  no installed certificate covers $DOMAIN"
    fi

    if [ -L "$NGINX_ENABLED" ]; then ok "nginx site   enabled"; else bad "nginx site   not enabled"; fi

    # An end-to-end request proves the whole chain, not just that things are up.
    if command -v curl >/dev/null 2>&1; then
        local code
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null || true)"
        case "$code" in
            200|301|302) ok "https://$DOMAIN -> $code" ;;
            ""|000) bad "https://$DOMAIN unreachable" ;;
            *) warn "https://$DOMAIN -> $code" ;;
        esac
    fi
    printf '\n'
}

# -------------------------------------------------------------------- logs --
show_logs() {
    if [ ! -t 0 ]; then
        journalctl -u "$SERVICE_NAME" -n 100 --no-pager
        return 0
    fi
    printf '\n%s==>%s %sLogs%s\n\n' "$BLUE" "$RESET" "$BOLD" "$RESET"
    printf '      %s1%s  Last 100 lines of %s\n' "$BOLD" "$RESET" "$SERVICE_NAME"
    printf '      %s2%s  Follow %s live (Ctrl-C to stop)\n' "$BOLD" "$RESET" "$SERVICE_NAME"
    printf '      %s3%s  Nginx error log\n' "$BOLD" "$RESET"
    printf '      %s4%s  Django error log (logs/)\n' "$BOLD" "$RESET"
    printf '      %sb%s  Back\n\n' "$BOLD" "$RESET"
    printf '    Choice: '
    local choice
    read -r choice || choice="b"
    case "$choice" in
        1) journalctl -u "$SERVICE_NAME" -n 100 --no-pager ;;
        2) journalctl -u "$SERVICE_NAME" -f || true ;;
        3) tail -n 100 /var/log/nginx/error.log 2>/dev/null || warn "no /var/log/nginx/error.log" ;;
        4) local latest
           latest="$(find "$PROJECT_DIR/logs" -name 'errors_*.log' -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
           if [ -n "$latest" ]; then info "$latest"; tail -n 100 "$latest"; else warn "no Django error log yet"; fi ;;
        *) : ;;
    esac
}

# ---------------------------------------------------------------- database --
backup_database() {
    database_is_local || die "the database is not local to this host; back it up where it lives."
    step "Backing up $DB_NAME"
    as_run_user mkdir -p "$BACKUP_DIR"
    local stamp file
    stamp="$(date +%Y%m%d-%H%M%S)"
    file="$BACKUP_DIR/${DB_NAME}_${stamp}.dump"
    # -Fc: compressed custom format, restorable with pg_restore.
    sudo -u postgres pg_dump -Fc "$DB_NAME" > "$file"
    chown "$RUN_USER:$RUN_GROUP" "$file"
    chmod 600 "$file"
    ok "wrote $file ($(du -h "$file" | cut -f1))"
}

restore_database() {
    local file="$1" restart_after=0
    database_is_local || die "the database is not local to this host."
    [ -f "$file" ] || die "no such dump: $file"
    warn "restoring drops and recreates every table in $DB_NAME."
    yes_no "Restore $file into $DB_NAME?" || { info "nothing was changed."; return 0; }

    step "Restoring $DB_NAME"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "stopping $SERVICE_NAME during the restore"
        systemctl stop "$SERVICE_NAME"
        restart_after=1
    fi
    # --clean complains about objects that a fresh database does not have yet,
    # which is noise rather than failure, so this one is allowed to be noisy.
    sudo -u postgres pg_restore --clean --if-exists --no-owner --role="$DB_USER" \
        -d "$DB_NAME" "$file" || warn "pg_restore reported errors (usually harmless --clean noise)"
    psql_su_db "$DB_NAME" "REASSIGN OWNED BY postgres TO \"$DB_USER\"" >/dev/null 2>&1 || true
    ok "restored from $file"
    if [ "$restart_after" -eq 1 ]; then
        systemctl start "$SERVICE_NAME"
        ok "$SERVICE_NAME started again"
    fi
}

# Drops the database and rebuilds it from migrations. Needed when the user
# model changes: swapping AUTH_USER_MODEL after auth's migrations have already
# run leaves a history Django refuses to continue from.
reset_database() {
    database_is_local || die "the database is not local to this host."
    require_venv

    step "Reset $DB_NAME"
    bad "this DROPS $DB_NAME and every row in it."
    info "a backup is written to $BACKUP_DIR_NAME/ first, unless the database is missing."

    if [ "$ASSUME_YES" -eq 0 ]; then
        [ -t 0 ] || die "refusing to drop a database with no terminal attached; pass --yes if you mean it."
        printf '    Type the database name to confirm [%s]: ' "$DB_NAME"
        local confirm
        read -r confirm || confirm=""
        if [ "$confirm" != "$DB_NAME" ]; then
            info "that did not match; nothing was changed."
            return 0
        fi
    fi

    if [ "$(psql_su "SELECT 1 FROM pg_database WHERE datname = '$(sql_lit "$DB_NAME")'")" = "1" ]; then
        backup_database
    else
        info "$DB_NAME does not exist yet; nothing to back up"
    fi

    local restart_after=0
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        info "stopping $SERVICE_NAME so its connections do not block the drop"
        systemctl stop "$SERVICE_NAME"
        restart_after=1
    fi

    # Any other open session on the database would make DROP fail.
    psql_su "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$(sql_lit "$DB_NAME")' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true
    psql_su "DROP DATABASE IF EXISTS \"$DB_NAME\"" >/dev/null
    ok "dropped $DB_NAME"

    provision_database

    step "Migrating the new database"
    manage migrate --noinput
    ok "migrations applied"

    ensure_superuser

    if [ "$restart_after" -eq 1 ]; then
        systemctl start "$SERVICE_NAME"
        ok "$SERVICE_NAME started again"
    fi
}

database_menu() {
    if [ -n "$RESTORE_FILE" ]; then
        restore_database "$RESTORE_FILE"
        return 0
    fi
    if [ ! -t 0 ]; then
        provision_database
        return 0
    fi

    printf '\n%s==>%s %sDatabase%s  %s%s@%s%s\n\n' "$BLUE" "$RESET" "$BOLD" "$RESET" "$DIM" "$DB_NAME" "$DB_HOST" "$RESET"
    printf '      %s1%s  Create or repair   role, database, grants, from .env\n' "$BOLD" "$RESET"
    printf '      %s2%s  Back up            pg_dump into %s/\n' "$BOLD" "$RESET" "$BACKUP_DIR_NAME"
    printf '      %s3%s  Restore            from a dump in %s/\n' "$BOLD" "$RESET" "$BACKUP_DIR_NAME"
    printf '      %s4%s  Migrate            manage.py migrate\n' "$BOLD" "$RESET"
    printf '      %s5%s  psql shell         connect as %s\n' "$BOLD" "$RESET" "$DB_USER"
    printf '      %s6%s  Reset              %sdrop and rebuild, destroys every row%s\n' "$BOLD" "$RESET" "$RED" "$RESET"
    printf '      %sb%s  Back\n\n' "$BOLD" "$RESET"
    printf '    Choice: '
    local choice
    read -r choice || choice="b"
    case "$choice" in
        1) provision_database ;;
        2) backup_database ;;
        3) local dumps=() f i=1 pick
           if [ -d "$BACKUP_DIR" ]; then
               while IFS= read -r f; do dumps+=("$f"); done \
                   < <(find "$BACKUP_DIR" -maxdepth 1 -name '*.dump' -type f | sort -r)
           fi
           if [ "${#dumps[@]}" -eq 0 ]; then warn "no dumps in $BACKUP_DIR"; return 0; fi
           printf '\n'
           for f in "${dumps[@]}"; do
               printf '      %s%d%s  %s\n' "$BOLD" "$i" "$RESET" "$(basename "$f")"
               i=$((i + 1))
           done
           printf '\n    Dump to restore: '
           read -r pick || pick=""
           case "$pick" in
               ''|*[!0-9]*) info "nothing was changed." ;;
               *) if [ "$pick" -ge 1 ] && [ "$pick" -le "${#dumps[@]}" ]; then
                      restore_database "${dumps[$((pick - 1))]}"
                  else
                      warn "out of range."
                  fi ;;
           esac ;;
        4) require_venv; manage migrate --noinput; ok "migrations applied" ;;
        5) database_is_local || die "the database is not on this host."
           PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" || true ;;
        6) reset_database ;;
        *) : ;;
    esac
}

# ------------------------------------------------------------ django tools --
django_menu() {
    require_venv
    if [ "${#MANAGE_ARGS[@]}" -gt 0 ]; then
        step "manage.py ${MANAGE_ARGS[*]}"
        manage "${MANAGE_ARGS[@]}"
        return 0
    fi
    [ -t 0 ] || die "--django needs a command, e.g. --django createsuperuser"

    printf '\n%s==>%s %sDjango%s\n\n' "$BLUE" "$RESET" "$BOLD" "$RESET"
    printf '      %s1%s  Create a superuser\n' "$BOLD" "$RESET"
    printf '      %s2%s  Change a password\n' "$BOLD" "$RESET"
    printf '      %s3%s  Collect static files\n' "$BOLD" "$RESET"
    printf '      %s4%s  Deployment checks\n' "$BOLD" "$RESET"
    printf '      %s5%s  Django shell\n' "$BOLD" "$RESET"
    printf '      %s6%s  Any manage.py command\n' "$BOLD" "$RESET"
    printf '      %sb%s  Back\n\n' "$BOLD" "$RESET"
    printf '    Choice: '
    local choice u c
    read -r choice || choice="b"
    case "$choice" in
        1) manage createsuperuser || warn "createsuperuser did not complete." ;;
        2) printf '    Username: '
           read -r u || u=""
           if [ -n "$u" ]; then manage changepassword "$u"; else warn "no username given."; fi ;;
        3) manage collectstatic --noinput --clear >/dev/null && ok "static files collected" ;;
        4) manage check --deploy ;;
        5) manage shell ;;
        6) printf '    manage.py '
           read -r c || c=""
           # Deliberately unquoted: the operator typed a whole command line.
           if [ -n "$c" ]; then manage $c; else warn "nothing given."; fi ;;
        *) : ;;
    esac
}

# --------------------------------------------------------------- uninstall --
uninstall_site() {
    step "Uninstall"
    warn "this removes the systemd unit and the nginx site for $DOMAIN."
    info "the code, $VENV_DIR, the database and .env are left alone."
    yes_no "Proceed?" || { info "nothing was changed."; return 0; }

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl stop "$SERVICE_NAME"
        info "stopped $SERVICE_NAME"
    fi
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [ -f "$UNIT_PATH" ]; then
        rm -f "$UNIT_PATH"
        systemctl daemon-reload
        info "removed $UNIT_PATH"
    fi
    if [ -e "$NGINX_ENABLED" ] || [ -L "$NGINX_ENABLED" ]; then
        rm -f "$NGINX_ENABLED"
        info "removed $NGINX_ENABLED"
        if nginx -t >/dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || true
        fi
    fi
    ok "uninstalled. The site config is still at $NGINX_AVAILABLE if you want it back."
    info "certificate kept -- delete it with: certbot delete --cert-name $(basename "${CERT_DIR:-$DOMAIN}")"
}

# ----------------------------------------------------------------- actions --
summary() {
    step "Done ($MODE -- $(component_label "$COMPONENT"))"
    printf '    %-12s %s\n' "site"    "https://$DOMAIN"
    printf '    %-12s %s\n' "admin"   "https://$DOMAIN$ADMIN_PATH"
    case "$COMPONENT" in
        site)
            printf '    %-12s %s\n' "downloads" "https://$DOMAIN/downloads/"
            printf '    %-12s %s\n' "console"   "https://$DOMAIN/console/stats/"
            ;;
        api)
            printf '    %-12s %s\n' "health"    "https://$DOMAIN/api/health/"
            printf '    %-12s %s\n' "app logs"  "https://$DOMAIN${ADMIN_PATH}logs/"
            ;;
    esac
    printf '    %-12s %s\n' "venv"    "$VENV_PATH"
    printf '    %-12s %s\n' "service" "systemctl status $SERVICE_NAME"
    printf '    %-12s %s\n' "logs"    "journalctl -u $SERVICE_NAME -f"
    printf '\n'
}

run_fresh() {
    do_apt
    ensure_secret_key
    provision_database
    build_venv 1
    run_django_steps
    ensure_superuser
    install_unit
    restart_service
    obtain_certificate
    install_nginx_site
    reload_nginx
    install_renewal_hook
    configure_firewall
    summary
}

run_update() {
    # apt is deliberately skipped: a routine deploy should not be able to pull
    # in a new nginx or python under a running site. The database is left
    # alone as well -- only migrations touch it.
    ensure_secret_key
    require_venv
    build_venv 0
    run_django_steps
    install_unit
    restart_service
    obtain_certificate
    install_nginx_site
    reload_nginx
    install_renewal_hook
    summary
}

run_restart() {
    restart_service
    reload_nginx
    summary
}

# -------------------------------------------------------------------- menu --
show_menu() {
    local target
    if [ "$COMPONENT_ARG" = "all" ]; then
        target="both projects"
    else
        target="$(component_label "$COMPONENT_ARG")"
    fi
    printf '\n%s==>%s %sWhat should this run?%s  %s%s%s\n\n' \
        "$BLUE" "$RESET" "$BOLD" "$RESET" "$DIM" "$target" "$RESET"
    printf '      %s1%s  Fresh install   apt, PostgreSQL, virtualenv, dependencies, migrate,\n' "$BOLD" "$RESET"
    printf '                          static, superuser, service, nginx, firewall\n\n'
    printf '      %s2%s  Update          dependencies, migrate, static, re-render, restart\n\n' "$BOLD" "$RESET"
    printf '      %s3%s  Restart         restart gunicorn, reload nginx\n\n' "$BOLD" "$RESET"
    printf '      %s4%s  Status          service, port, database, certificate\n' "$BOLD" "$RESET"
    printf '      %s5%s  Logs            gunicorn, nginx, Django\n' "$BOLD" "$RESET"
    printf '      %s6%s  Database        create, back up, restore, psql\n' "$BOLD" "$RESET"
    printf '      %s7%s  Django          superuser, shell, manage.py\n' "$BOLD" "$RESET"
    printf '      %s8%s  Renew TLS       run certbot renew for this site\n' "$BOLD" "$RESET"
    printf '      %s9%s  Uninstall       remove the service and the nginx site\n\n' "$BOLD" "$RESET"
    printf '      %sc%s  Change project\n' "$BOLD" "$RESET"
    printf '      %sq%s  Quit\n\n' "$BOLD" "$RESET"
}

choose_mode() {
    MODE=""
    while [ -z "$MODE" ]; do
        show_menu
        printf '    Choice [1-9/c/q]: '
        local choice
        read -r choice || choice="q"
        case "$choice" in
            c|C) MODE="switch" ;;
            1) MODE="fresh" ;;
            2) MODE="update" ;;
            3) MODE="restart" ;;
            4) MODE="status" ;;
            5) MODE="logs" ;;
            6) MODE="database" ;;
            7) MODE="django" ;;
            8) MODE="renew" ;;
            9) MODE="uninstall" ;;
            q|Q) info "nothing was changed."; exit 0 ;;
            *) warn "pick a number from 1 to 9, c to change project, or q." ;;
        esac
    done
}

run_mode() {
    RETURN_TO_MENU=0
    case "$MODE" in
        fresh)     run_fresh ;;
        update)    run_update ;;
        restart)   run_restart ;;
        status)    show_status;   RETURN_TO_MENU=1 ;;
        logs)      show_logs;     RETURN_TO_MENU=1 ;;
        database)  database_menu; RETURN_TO_MENU=1 ;;
        django)    django_menu;   RETURN_TO_MENU=1 ;;
        renew)     renew_certificate ;;
        uninstall) uninstall_site ;;
        *)         die "unknown action: $MODE" ;;
    esac
}

# ---------------------------------------------------------------- dispatch --
# Each project is configured from scratch immediately before its action runs,
# so nothing from the first leaks into the second.
run_for_targets() {
    local targets=() target

    if [ "$COMPONENT_ARG" = "all" ]; then
        # These three act on one database, one shell or one unit. Applying them
        # to both projects in turn is not what anyone means by "all", so they
        # have to name their target.
        case "$MODE" in
            database|django|uninstall)
                die "--all cannot be used with the $MODE action; name one project with --site or --api." ;;
        esac
        targets=("${COMPONENTS[@]}")
    else
        targets=("$COMPONENT_ARG")
    fi

    for target in "${targets[@]}"; do
        select_component "$target"
        read_config
        info "action     $MODE"
        run_mode
    done
}

choose_component() {
    printf '\n%s==>%s %sWhich project?%s\n\n' "$BLUE" "$RESET" "$BOLD" "$RESET"
    printf '      %s1%s  Downloads site      apps.felixmokayabeatz.online   ./\n' "$BOLD" "$RESET"
    printf '      %s2%s  Authenticator API   api.felixmokayabeatz.online    ./otp_backend/\n' "$BOLD" "$RESET"
    printf '      %s3%s  Both                one after the other\n\n' "$BOLD" "$RESET"
    printf '      %sq%s  Quit\n\n' "$BOLD" "$RESET"
    while [ -z "$COMPONENT_ARG" ]; do
        printf '    Choice [1-3/q]: '
        local choice
        read -r choice || choice="q"
        case "$choice" in
            1) COMPONENT_ARG="site" ;;
            2) COMPONENT_ARG="api" ;;
            3) COMPONENT_ARG="all" ;;
            q|Q) info "nothing was changed."; exit 0 ;;
            *) warn "pick 1, 2, 3 or q." ;;
        esac
    done
}

if [ -n "$MODE" ]; then
    if [ -z "$COMPONENT_ARG" ]; then
        if [ -t 0 ]; then
            choose_component
        else
            # An action named on a pipeline with no project meant is taken to
            # mean the whole host; run_for_targets still refuses the ones that
            # cannot be applied to both.
            COMPONENT_ARG="all"
        fi
    fi
    run_for_targets
    exit 0
fi

if [ ! -t 0 ]; then
    MODE="update"
    COMPONENT_ARG="${COMPONENT_ARG:-all}"
    info "no terminal attached; defaulting to --update."
    run_for_targets
    exit 0
fi

# The read-only actions come back to the menu; anything that changes the
# server finishes with its own summary and exits.
while :; do
    [ -n "$COMPONENT_ARG" ] || choose_component
    choose_mode
    if [ "$MODE" = "switch" ]; then
        COMPONENT_ARG=""
        continue
    fi
    run_for_targets
    [ "$RETURN_TO_MENU" -eq 1 ] || break
done
