#!/usr/bin/env bash
# =============================================================================
# ONE command for the whole chain:   M-NVR  ->  bridge  ->  CMS  ->  RPF
#
#   bash start.sh              start everything (first run also sets up the databases)
#   bash start.sh stop         stop everything (never Postgres)
#   bash start.sh status       what is running
#   bash start.sh logs [mnvr|cms|rpf|bridge]
#   bash start.sh reset-passwords   set every account (M-NVR, CMS, RPF) to Admin@123
#   bash start.sh diagnose-footage  show where footage is written / looked up and what the upload chain logged
#   bash start.sh check-footage     list delivered footage whose file is missing in the footage folder (<project>/media)
#   bash start.sh --demo-data  (with start) also load demo zones/posts/logins into a fresh CMS
#
# It does everything itself, every time (safe to re-run): installs missing system tools and npm packages, starts
# PostgreSQL, creates every .env, removes files left over from older versions, sets up the databases, starts
# the apps. The bridge reads the unit name and train number from the M-NVR and registers it in CMS by itself.
# It asks nothing.
# Needs: Linux with Node 18+, PostgreSQL 15+ with PostGIS, ffmpeg, psql, curl (installed for you if sudo allows).
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MNVR="$ROOT/mnvr"; RPFD="$ROOT/RPF_CMS/rpf"; CMSD="$ROOT/RPF_CMS/CMS"; BR="$ROOT/bridge"
LOGS="$ROOT/logs"; mkdir -p "$LOGS"
say(){ printf '\033[32m==>\033[0m %s\n' "$*"; }; warn(){ printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }; die(){ printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
envget(){ [[ -f "$1" ]] && grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2- | sed -e 's/^["'\'']//' -e 's/["'\'']$//'; }
wait_url(){ for _ in $(seq 1 "${3:-90}"); do curl -fs -m 2 -o /dev/null "$1" && return 0; sleep 1; done; return 1; }


# ---- every account -> Admin@123 -------------------------------------------------------------------------------------------
DEFAULT_PW="Admin@123"
do_reset_passwords() {
  local ok=1
  say "setting every account to $DEFAULT_PW"
  # CMS + RPF share one users table
  ( cd "$RPFD" && node -e "
      const bcrypt = require('bcryptjs'); const { pool } = require('./src/db');
      (async () => { const h = await bcrypt.hash(process.argv[1], 10);
        const r = await pool.query(\"UPDATE users SET password_hash = \$1 WHERE username <> 'system'\", [h]);
        console.log('  CMS + RPF accounts updated: ' + r.rowCount); await pool.end(); })().catch((e) => { console.error('  CMS/RPF: ' + e.message); process.exit(1); })" "$DEFAULT_PW" ) || ok=0
  # M-NVR (the analytics worker's service account is left alone)
  ( cd "$MNVR/backend/api" && node scripts/reset_password.js --all "$DEFAULT_PW" ) || ok=0
  if [[ $ok == 1 ]]; then touch "$ROOT/data/.passwords-reset"; say "done - every login is now $DEFAULT_PW (change it afterwards under Account / Password)"; else warn "some accounts could not be updated - run again once the apps are up:  bash start.sh reset-passwords"; fi
  return 0
}

# ---- system tools -------------------------------------------------------------------------------------------------------
SUDO=""; [[ $EUID -ne 0 ]] && command -v sudo >/dev/null && sudo -n true 2>/dev/null && SUDO="sudo"
ensure_system() {
  local missing=() c
  for c in node npm psql curl ffmpeg python3; do command -v "$c" >/dev/null || missing+=("$c"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  local pk=(); for c in "${missing[@]}"; do case "$c" in node|npm) pk+=(nodejs npm);; psql) pk+=(postgresql-client);; python3) pk+=(python3 python3-pip python3-venv);; *) pk+=("$c");; esac; done
  if command -v apt-get >/dev/null && { [[ $EUID -eq 0 ]] || [[ -n "$SUDO" ]]; }; then
    say "installing missing tools: ${missing[*]}"; $SUDO apt-get update -qq >/dev/null 2>&1; $SUDO apt-get install -y -qq "${pk[@]}" >/dev/null 2>&1 || true
  fi
  for c in "${missing[@]}"; do command -v "$c" >/dev/null || die "$c is not installed. Run:  sudo apt install -y ${pk[*]}   (then run start.sh again)"; done
}
ensure_postgres() {
  if command -v pg_isready >/dev/null && pg_isready -q -h localhost 2>/dev/null; then return 0; fi
  say "starting PostgreSQL"
  { $SUDO systemctl start postgresql || $SUDO service postgresql start; } >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do pg_isready -q -h localhost 2>/dev/null && return 0; sleep 1; done
  warn "PostgreSQL is not answering on localhost:5432 - install/start it (sudo apt install postgresql postgis) and run start.sh again"
}

# ---- npm packages: install whatever is missing (the individual launchers only install when node_modules is absent) -------
ensure_npm() {
  local d="$1"; [[ -f "$d/package.json" ]] || return 0
  if [[ ! -d "$d/node_modules" ]] || ! (cd "$d" && npm ls --depth=0 >/dev/null 2>&1); then
    say "installing packages: ${d#$ROOT/}"
    (cd "$d" && npm install --no-audit --no-fund --silent) >> "$LOGS/npm-install.log" 2>&1 || { tail -n 15 "$LOGS/npm-install.log" >&2; die "npm install failed in ${d#$ROOT/}"; }
  fi
}

# ---- files left over from older versions of these apps (they would confuse or break the current ones) --------------------
remove_obsolete() {
  local f
  for f in RPF_CMS/rpf/src/services/security.js RPF_CMS/rpf/src/routes/admin.js RPF_CMS/rpf/data/security.json \
           RPF_CMS/CMS/backend/src/services/recovery.js mnvr/backend/api/src/services/recovery.js \
           mnvr/frontend/src/components/RecoveryCodeBox.tsx \
           RPF_CMS/rpf/src/services/emails.js RPF_CMS/rpf/src/services/mailer.js RPF_CMS/rpf/src/services/resetTokens.js \
           RPF_CMS/CMS/backend/src/services/emails.js RPF_CMS/CMS/backend/src/services/mailer.js RPF_CMS/CMS/backend/src/services/resetTokens.js \
           mnvr/backend/api/src/services/mailer.js mnvr/backend/api/src/services/resetTokens.js mnvr/frontend/src/pages/ResetPassword.tsx \
           RPF_CMS/rpf/test/helpers/smtp-sink.js mail.env mail.env.example data/emails.json; do
    [[ -e "$ROOT/$f" ]] && rm -f "$ROOT/$f" && say "removed old file $f"
  done
  return 0
}


# ---- database passwords: CMS role = "cms" / password "cms" (kept in the .env files for good), no manual .env editing ---------
CMS_DB_PW="${CMS_DB_PASSWORD:-cms}"
setkv(){ local f="$1" k="$2" v="$3"; [[ -f "$f" ]] || return 0; if grep -qE "^$k=" "$f"; then sed -i "s|^$k=.*|$k=$v|" "$f"; else printf '\n%s=%s\n' "$k" "$v" >> "$f"; fi; }
# run one SQL statement as the PostgreSQL superuser. Runs in the foreground, so sudo can ask for your password here.
pg_su(){
  local sql="$1" sp su
  if [[ $EUID -eq 0 ]]; then ( cd /tmp && runuser -u postgres -- psql -qtAc "$sql" ) 2>/dev/null && return 0
  elif command -v sudo >/dev/null; then ( cd /tmp && sudo -u postgres psql -qtAc "$sql" ) 2>/dev/null && return 0; fi
  sp="$(envget "$RPFD/.env" PG_SUPERUSER_PASSWORD)"; su="$(envget "$RPFD/.env" PG_SUPERUSER)"
  [[ -n "$sp" ]] && PGPASSWORD="$sp" psql -h localhost -U "${su:-postgres}" -d postgres -qtAc "$sql" 2>/dev/null
}
fix_cms_role(){   # make .env and the PostgreSQL role agree on the password "cms"
  local u; u="$(envget "$RPFD/.env" DB_USER)"; u="${u:-cms}"
  local f; for f in "$RPFD/.env" "$CMSD/backend/.env" "$ROOT/.env"; do setkv "$f" DB_PASSWORD "$CMS_DB_PW"; done
  if [[ "$(pg_su "SELECT 1 FROM pg_roles WHERE rolname='$u'")" == "1" ]]; then
    pg_su "ALTER ROLE $u WITH LOGIN PASSWORD '$CMS_DB_PW'" >/dev/null && say "database role '$u' now uses the password from .env" \
      || warn "could not change the password of role '$u' (no sudo / postgres access) - run: sudo -u postgres psql -c \"ALTER ROLE $u PASSWORD '$CMS_DB_PW'\""
  fi
}
ensure_cms_db_password(){
  local u; u="$(envget "$RPFD/.env" DB_USER)"; u="${u:-cms}"
  local f; for f in "$RPFD/.env" "$CMSD/backend/.env" "$ROOT/.env"; do setkv "$f" DB_PASSWORD "$CMS_DB_PW"; done
  PGPASSWORD="$CMS_DB_PW" psql -h localhost -U "$u" -d postgres -tAc 'select 1' >/dev/null 2>&1 && return 0
  fix_cms_role
}
# M-NVR database (role + database "mnvr", password "mnvr"): created HERE in the foreground, because the M-NVR launcher runs in the
# background where sudo cannot ask for a password (that was why the first-run setup silently did nothing)
ensure_mnvr_db(){
  local pw="$1"
  PGPASSWORD="$pw" psql -h localhost -U mnvr -d mnvr -tAc 'select 1' >/dev/null 2>&1 && return 0
  say "preparing the M-NVR database (sudo may ask for your password)"
  pg_su "CREATE ROLE mnvr LOGIN PASSWORD '$pw'" >/dev/null || true
  pg_su "ALTER ROLE mnvr WITH LOGIN PASSWORD '$pw'" >/dev/null || true
  pg_su "CREATE DATABASE mnvr OWNER mnvr" >/dev/null || true
  pg_su "GRANT ALL PRIVILEGES ON DATABASE mnvr TO mnvr" >/dev/null || true
  PGPASSWORD="$pw" psql -h localhost -U mnvr -d mnvr -tAc 'select 1' >/dev/null 2>&1 \
    || warn "could not create/open the M-NVR database - run: sudo -u postgres psql -c \"CREATE ROLE mnvr LOGIN PASSWORD '$pw'\" -c \"CREATE DATABASE mnvr OWNER mnvr\""
}

# ---- ONE footage folder for CMS + RPF (this is what "footage file is not reachable from the RPF server" was about) ---------
# CMS writes delivered footage into its MEDIA_ROOT and RPF reads it from its own: if the two (or two start-ups) differ, the
# database says "delivered" while the file is somewhere else. Both are pinned to one absolute folder here, on every start,
# and anything already in the old per-app folders is copied over (nothing is overwritten or deleted).
MEDIA_DIR="${IPVSS_MEDIA_DIR:-$ROOT/media}"
setup_media() {
  mkdir -p "$MEDIA_DIR" || die "cannot create the footage folder $MEDIA_DIR"
  local old f
  for old in "$RPFD/media" "$CMSD/media" "$CMSD/backend/media"; do
    [[ -d "$old" && "$(cd "$old" && pwd)" != "$MEDIA_DIR" ]] && cp -an "$old"/. "$MEDIA_DIR"/ 2>/dev/null
  done
  for f in "$RPFD/.env" "$CMSD/backend/.env" "$ROOT/.env"; do setkv "$f" MEDIA_ROOT "$MEDIA_DIR"; done
  export MEDIA_ROOT="$MEDIA_DIR"      # an exported value wins over .env for every process started below, also on a first run
}

# Old copies of CMS / RPF / bridge / M-NVR API left running from ANOTHER folder (an earlier install) keep their own footage
# folder and their own background workers on the same database: they deliver a request and store the file in THEIR folder, so
# the new copy finds a "delivered" record without a file. They are stopped here (their footage is copied over first).
retire_foreign_services() {
  local pid cwd media
  for pid in $(pgrep -f "node src/(server|index)\.js" 2>/dev/null); do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"; [[ -n "$cwd" ]] || continue
    case "$cwd" in "$ROOT"/*) continue;; esac
    case "$cwd" in */RPF_CMS/CMS/backend|*/RPF_CMS/rpf|*/bridge|*/mnvr/backend/api) ;; *) continue;; esac
    media="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^MEDIA_ROOT=//p' | head -n1)"
    case "$cwd" in */RPF_CMS/CMS/backend) media="${media:-$cwd/../../media}";; */RPF_CMS/rpf) media="${media:-$cwd/media}";; *) media="";; esac
    if [[ -n "$media" && -d "$media" && "$(cd "$media" && pwd)" != "$MEDIA_DIR" ]]; then
      warn "an old copy is running from $cwd (pid $pid) - copying its footage into $MEDIA_DIR and stopping it"
      cp -a "$media"/. "$MEDIA_DIR"/ 2>/dev/null
    else
      warn "an old copy is running from $cwd (pid $pid) - stopping it"
    fi
    kill "$pid" 2>/dev/null; sleep 0.5; kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
  return 0
}
# after start-up: does the CMS that is really running store footage where RPF and this script expect it?
verify_media() {
  local cms rpf
  cms="$(curl -fs -m 3 "http://localhost:$CMS_PORT/health" 2>/dev/null | sed -n 's/.*"media_root":"\([^"]*\)".*/\1/p')"
  rpf="$(curl -fs -m 3 "http://localhost:$(envget "$RPFD/.env" PORT || echo 7090)/health" 2>/dev/null | sed -n 's/.*"media_root":"\([^"]*\)".*/\1/p')"
  [[ -n "$cms" && "$cms" == "$MEDIA_DIR" && "$rpf" == "$MEDIA_DIR" ]] && { say "footage folder OK: CMS and RPF both use $MEDIA_DIR"; return 0; }
  warn "footage folders differ - CMS: ${cms:-?}   RPF: ${rpf:-?}   expected: $MEDIA_DIR   (RPF follows the CMS automatically; details: bash start.sh diagnose-footage)"
}

# bash start.sh check-footage : every delivered file the database knows must be in the footage folder. A missing one is
# searched for in the project, /storage and your home folder (older folders, other start-ups) and copied into place.
do_check_footage() {
  local quiet="${1:-}" u p n bad=0 fixed=0 total=0 id path hit
  u="$(envget "$RPFD/.env" DB_USER)"; u="${u:-cms}"; n="$(envget "$RPFD/.env" DB_NAME)"; n="${n:-cms}"; p="$(envget "$RPFD/.env" DB_PASSWORD)"; p="${p:-$CMS_DB_PW}"
  [[ -z "$quiet" ]] && say "footage folder: $MEDIA_DIR"
  while IFS='|' read -r id path; do
    [[ -z "$id" || -z "$path" ]] && continue; total=$((total+1))
    [[ -f "$MEDIA_DIR/$path" ]] && continue
    hit="$(find "$ROOT" /storage "$HOME" -xdev -maxdepth 12 \( -name node_modules -o -name .git -o -name .venv -o -name .cache \) -prune -o -type f -path "*/$path" -not -path "$MEDIA_DIR/*" -print 2>/dev/null | head -n1)"
    if [[ -n "$hit" ]] && mkdir -p "$(dirname "$MEDIA_DIR/$path")" && cp "$hit" "$MEDIA_DIR/$path"; then fixed=$((fixed+1)); echo "  recovered #$id  $path   (found in $hit)"
    else bad=$((bad+1)); [[ -z "$quiet" ]] && echo "  missing:  #$id  $path"; fi
  done < <(PGPASSWORD="$p" psql -h localhost -U "$u" -d "$n" -tA -F'|' -c "SELECT id, storage_path FROM delivered_footage ORDER BY id" 2>/dev/null)
  [[ -n "$quiet" && $bad -eq 0 && $fixed -eq 0 ]] && return 0
  [[ -n "$quiet" ]] && { echo "  footage check: $fixed file(s) recovered, $bad delivered file(s) not on this machine (list them: bash start.sh check-footage)"; return 0; }
  echo "  $total delivered file(s) in the database: $fixed recovered, $bad still missing."
  [[ $bad -gt 0 ]] && echo "  A still-missing file was never stored on this machine - run:  bash start.sh diagnose-footage   and send me the output."
  return 0
}
# bash start.sh diagnose-footage : shows where footage is written/looked up and what the upload chain logged
do_diagnose_footage() {
  local pid cwd f
  say "footage folder (shared by CMS + RPF): $MEDIA_DIR"
  for f in "$RPFD/.env" "$CMSD/backend/.env"; do echo "  ${f#$ROOT/}: MEDIA_ROOT=$(envget "$f" MEDIA_ROOT)"; done
  for pid in $(pgrep -f "node src/server.js" 2>/dev/null); do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)"
    echo "  running ${cwd#$ROOT/} (pid $pid): MEDIA_ROOT=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^MEDIA_ROOT=//p')"
  done
  local cp; cp="$(envget "$RPFD/.env" CMS_PORT)"; cp="${cp:-7080}"
  for f in "$cp" "$(envget "$RPFD/.env" PORT)"; do [[ -n "$f" ]] && echo "  /health on :$f -> $(curl -fs -m 3 "http://localhost:$f/health" 2>/dev/null | cut -c1-300)"; done
  echo "  files in the footage folder:"; find "$MEDIA_DIR" -type f 2>/dev/null | head -n 20 | sed 's/^/    /'
  echo "  any req-*.mp4 elsewhere:"; find "$ROOT" /storage -xdev -maxdepth 8 \( -name node_modules -o -name .git \) -prune -o -type f -name 'req-*.mp4' -print 2>/dev/null | head -n 10 | sed 's/^/    /'
  local u p n; u="$(envget "$RPFD/.env" DB_USER)"; u="${u:-cms}"; n="$(envget "$RPFD/.env" DB_NAME)"; n="${n:-cms}"; p="$(envget "$RPFD/.env" DB_PASSWORD)"; p="${p:-$CMS_DB_PW}"
  echo "  latest delivered_footage rows:"; PGPASSWORD="$p" psql -h localhost -U "$u" -d "$n" -x -c "SELECT * FROM delivered_footage ORDER BY id DESC LIMIT 2" 2>&1 | head -n 40 | sed 's/^/    /'
  echo "  M-NVR recordings folder: $(envget "$MNVR/backend/api/.env" RECORDINGS_PATH)  ($(find "$(envget "$MNVR/backend/api/.env" RECORDINGS_PATH)" -type f 2>/dev/null | wc -l) files)"
  echo "  log lines about uploads / footage / media (last 25):"
  grep -hiE "upload|footage|media|req-[0-9]+|stitch|no such file" "$LOGS"/*.log "$RPFD"/logs/*.log "$CMSD"/logs/*.log "$CMSD"/backend/logs/*.log "$BR"/logs/*.log 2>/dev/null | tail -n 25 | cut -c1-220 | sed 's/^/    /'
  return 0
}

mkdir -p "$ROOT/data"

CMD="start"; DEMO=0; ARG=""
for a in "$@"; do case "$a" in start|stop|status|logs|restart|reset-passwords|check-footage|diagnose-footage) CMD="$a";; --demo-data) DEMO=1;; *) ARG="$a";; esac; done

do_stop() {
  say "stopping bridge";  bash "$BR/scripts/start.sh" stop 2>/dev/null || true
  say "stopping M-NVR";   (cd "$MNVR" && bash scripts/start.sh --stop >/dev/null 2>&1) || true
  say "stopping CMS + RPF"; (cd "$RPFD" && bash scripts/start.sh stop >/dev/null 2>&1) || true
}

do_start() {
  ensure_system
  ensure_postgres
  remove_obsolete
  for d in "$RPFD" "$CMSD/backend" "$MNVR/backend/api" "$BR"; do ensure_npm "$d"; done   # (the M-NVR frontend installs itself)

  # 1. control room: database, CMS, RPF
  # a CMS left running from an earlier start may use a different footage folder than RPF: always start both fresh,
  # so they share one MEDIA_ROOT (rpf/media)
  (cd "$RPFD" && bash scripts/start.sh stop) >/dev/null 2>&1 || true
  ensure_cms_db_password
  setup_media
  retire_foreign_services
  say "starting CMS + RPF (database, schema, migrations on first run)"
  if ! (cd "$RPFD" && bash scripts/start.sh start) > "$LOGS/cms-rpf-start.log" 2>&1; then
    if grep -q "rejects the DB_PASSWORD" "$LOGS/cms-rpf-start.log"; then   # (.env was created after the check above)
      fix_cms_role
      (cd "$RPFD" && bash scripts/start.sh start) > "$LOGS/cms-rpf-start.log" 2>&1 || { tail -n 20 "$LOGS/cms-rpf-start.log" >&2; die "CMS/RPF did not start"; }
    else
      tail -n 20 "$LOGS/cms-rpf-start.log" >&2; die "CMS/RPF did not start"
    fi
  fi
  CMS_PORT="$(envget "$RPFD/.env" CMS_PORT)"; CMS_PORT="${CMS_PORT:-7080}"
  wait_url "http://localhost:$CMS_PORT/health" 60 || die "CMS does not answer on :$CMS_PORT (see logs/cms-rpf-start.log)"
  verify_media
  do_check_footage quiet     # footage that sits in an older folder is moved into the shared one
  if [[ $DEMO == 1 ]]; then
    say "loading demo zones, posts and logins"
    local P; P="$(envget "$RPFD/.env" DB_PASSWORD)"
    PGPASSWORD="$P" psql -h localhost -U "$(envget "$RPFD/.env" DB_USER || echo cms)" -d "$(envget "$RPFD/.env" DB_NAME || echo cms)" -q -f "$CMSD/sql/fixtures.sql" >/dev/null 2>&1 || warn "fixtures not applied (already loaded?)"
    (cd "$RPFD" && set -a && . ./.env && set +a && node scripts/seed_demo.js >/dev/null 2>&1) || true
  fi

  # 2. the train: M-NVR (first run creates its database)
  local MP; MP="$(envget "$MNVR/backend/api/.env" DB_PASSWORD)"; MP="${MP:-mnvr}"
  local MPORT; MPORT="$(envget "$MNVR/backend/api/.env" PORT)"; MPORT="${MPORT:-3001}"
  ensure_mnvr_db "$MP"
  local setup=""
  [[ -n "$(PGPASSWORD="$MP" psql -h localhost -U mnvr -d mnvr -tAc "select to_regclass('public.users')" 2>/dev/null)" ]] || setup="--setup-db"
  say "starting M-NVR ${setup:+(first run: database setup)}"
  (cd "$MNVR" && setsid nohup bash scripts/start.sh $setup > "$LOGS/mnvr.log" 2>&1 < /dev/null &)
  if wait_url "http://localhost:$MPORT/api/health" 240; then
    wait_url "http://localhost:8080" 90 || warn "M-NVR web page (:8080) is still starting - see logs/mnvr.log"
    MNVR_UP=1
  else
    MNVR_UP=0
    warn "M-NVR API is NOT answering on :$MPORT - last lines of logs/mnvr.log:"; tail -n 25 "$LOGS/mnvr.log" >&2
    warn "continuing - the bridge waits for it. Details:  bash start.sh logs mnvr"
  fi

  # 3. the bridge: settings are derived from the other two, nothing to fill in
  if [[ ! -f "$BR/.env" || -f "$BR/.env.generated" ]]; then
    say "configuring the bridge"
    {
      echo "CMS_URL=http://localhost:$CMS_PORT"
      echo "MNVR_DB_HOST=localhost"; echo "MNVR_DB_NAME=mnvr"; echo "MNVR_DB_USER=mnvr"; echo "MNVR_DB_PASSWORD=$MP"
      echo "CMS_DB_HOST=localhost"; echo "CMS_DB_NAME=$(envget "$RPFD/.env" DB_NAME || echo cms)"
      echo "CMS_DB_USER=$(envget "$RPFD/.env" DB_USER || echo cms)"; echo "CMS_DB_PASSWORD=$(envget "$RPFD/.env" DB_PASSWORD)"
      echo "RECORDINGS_DIR=$(envget "$MNVR/backend/api/.env" RECORDINGS_PATH)"
    } > "$BR/.env"; touch "$BR/.env.generated"
  fi
  say "starting the bridge"
  bash "$BR/scripts/start.sh" start || die "bridge did not start"
  sleep 4; curl -s -m 3 http://127.0.0.1:8095/health | grep -E '"online"|"mnvr_to_cms"' | head -2 || true

  [[ -f "$ROOT/data/.passwords-reset" ]] || do_reset_passwords   # once: every account -> Admin@123

  [[ "${MNVR_UP:-0}" == 1 ]] && echo "" && echo "  Everything is running." || { echo ""; echo "  CMS + RPF are running, but M-NVR is NOT up yet - see: bash start.sh logs mnvr"; }
  cat <<MSG
    M-NVR   http://localhost:8080     admin / Admin@123  (all logins: Admin@123)
    CMS     http://localhost:$CMS_PORT/console/
    RPF     http://localhost:$(envget "$RPFD/.env" PORT || echo 7090)
    Bridge  http://127.0.0.1:8095/health      logs: bash start.sh logs bridge
  Database password of the CMS role: $CMS_DB_PW  (kept in the .env files automatically)
  Footage folder (CMS + RPF share it): $MEDIA_DIR
  The first start downloads the AI packages in the background (a few GB) - M-NVR is usable meanwhile; progress: bash start.sh logs mnvr
  Stop all: bash start.sh stop
MSG
  [[ $DEMO == 0 ]] && echo "  First time: open the RPF address and fill in the Thana / Post registration form (the CMS needs at least one zone: create it in the CMS console, or run: bash start.sh --demo-data)"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0   # (sourced by a test: define the functions only)
case "$CMD" in
  start) do_start ;;
  stop) do_stop ;;
  restart) do_stop; do_start ;;
  status)
    (cd "$RPFD" && bash scripts/start.sh status) 2>&1 | tail -n 8
    (cd "$MNVR" && bash scripts/start.sh --status) 2>&1 | tail -n 12
    bash "$BR/scripts/start.sh" status ;;
  reset-passwords) do_reset_passwords ;;
  check-footage) do_check_footage ;;
  diagnose-footage) do_diagnose_footage ;;
  logs)
    case "$ARG" in mnvr) tail -n 80 -f "$LOGS/mnvr.log";; bridge) tail -n 80 -f "$BR/logs/bridge.log";; cms|rpf) (cd "$RPFD" && bash scripts/start.sh logs "$ARG");; *) (cd "$RPFD" && bash scripts/start.sh logs all);; esac ;;
esac
