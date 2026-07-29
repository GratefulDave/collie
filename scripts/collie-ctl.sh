#!/usr/bin/env bash
# Control script for Collie (the Herdr web bridge service). Invoked by the plugin's actions and usable directly.
# The bridge runs as a systemd --user service (NOT a Herdr plugin pane — see ARCHITECTURE.md §3), so it
# survives Herdr restarts and is supervised independently.
set -euo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNIT="collie"
UNIT_FILE="${HOME}/.config/systemd/user/${UNIT}.service"
PLUGIN_ID="herdr.collie"
LAUNCHD_LABEL="herdr.collie"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
USER_UID="${UID:-$(id -u)}"
CONFIG_ENV_NAMES=()

# Resolve the plugin config dir (where .env lives) the SAME way no matter how we're launched.
# Herdr injects HERDR_PLUGIN_CONFIG_DIR when it runs our actions, but a direct `collie-ctl.sh` call
# doesn't get it — so we ask Herdr for the canonical path (`herdr plugin config-dir`, plain text).
# Without this, the two entry points read DIFFERENT .env files (Herdr's dir vs a ~/.config/collie
# fallback), so a setting like COLLIE_SERVE_MODE applied one way and was silently ignored the other.
# Order: injected env → Herdr CLI → Herdr's conventional path (if it has a .env) → ~/.config/collie.
resolve_config_dir() {
  if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ]; then echo "$HERDR_PLUGIN_CONFIG_DIR"; return; fi
  if command -v herdr >/dev/null; then
    local d; d="$(herdr plugin config-dir "$PLUGIN_ID" 2>/dev/null || true)"
    if [ -n "$d" ]; then echo "$d"; return; fi
  fi
  local conventional="${HOME}/.config/herdr/plugins/config/${PLUGIN_ID}"
  if [ -f "${conventional}/.env" ]; then echo "$conventional"; return; fi
  echo "${HOME}/.config/collie"
}
CONFIG_DIR="$(resolve_config_dir)"

# If a legacy ~/.config/collie/.env exists but isn't the resolved dir, it's being ignored — say so
# rather than silently dropping config that used to apply via the old fallback.
if [ "$CONFIG_DIR" != "${HOME}/.config/collie" ] && [ -f "${HOME}/.config/collie/.env" ]; then
  echo "note: ignoring legacy ${HOME}/.config/collie/.env — config now lives in ${CONFIG_DIR}/.env (move it there)." >&2
fi

# Load only a constrained dotenv grammar; executing a config file as shell code turns write access
# to a secrets file into code execution. Values are literal (optionally wrapped in matching quotes).
# The launchd plist is generated from the parsed variables too, so macOS never needs a shell wrapper.
fatal() { echo "error: $*" >&2; exit 1; }

file_uid() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1"; }
file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

secure_config_dir() {
  if [ -e "$CONFIG_DIR" ]; then
    [ -d "$CONFIG_DIR" ] || fatal "${CONFIG_DIR} is not a directory"
    [ ! -L "$CONFIG_DIR" ] || fatal "refusing symlinked config directory: ${CONFIG_DIR}"
    [ "$(file_uid "$CONFIG_DIR")" = "$USER_UID" ] || fatal "${CONFIG_DIR} must be owned by uid ${USER_UID}"
  else
    mkdir -p -m 700 "$CONFIG_DIR"
  fi
  chmod 700 "$CONFIG_DIR" || fatal "could not restrict ${CONFIG_DIR} to owner-only access"
}

load_config_env() {
  local env_file="${CONFIG_DIR}/.env" line name value owner mode
  [ -e "$env_file" ] || return 0
  [ -f "$env_file" ] || fatal "${env_file} is not a regular file"
  [ ! -L "$env_file" ] || fatal "refusing symlinked config: ${env_file}"
  owner="$(file_uid "$env_file")"
  [ "$owner" = "$USER_UID" ] || fatal "${env_file} must be owned by uid ${USER_UID}"
  mode="$(file_mode "$env_file")"
  if [ "${mode#?}" != "00" ]; then
    chmod 600 "$env_file" || fatal "could not restrict ${env_file} to owner-only access"
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ""|\#*) continue ;; esac
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || fatal "invalid .env entry (expected NAME=value)"
    name="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ "$name" =~ ^COLLIE_[A-Z0-9_]+$ || "$name" = "HERDR_SOCKET_PATH" || "$name" = "HERDR_PLUGIN_STATE_DIR" ]] ||
      fatal "unsupported .env variable: ${name}"
    if [[ "$value" == \"*\" ]]; then
      [ "${#value}" -ge 2 ] && [ "${value:$((${#value} - 1)):1}" = "\"" ] ||
        fatal "unterminated double-quoted value for ${name}"
      value="${value:1:$((${#value} - 2))}"
    elif [[ "$value" == \'*\' ]]; then
      [ "${#value}" -ge 2 ] && [ "${value:$((${#value} - 1)):1}" = "'" ] ||
        fatal "unterminated single-quoted value for ${name}"
      value="${value:1:$((${#value} - 2))}"
    elif [[ "$value" == *\"* || "$value" == *\'* ]]; then
      fatal "quotes must wrap the complete value for ${name}"
    fi
    export "$name=$value"
    case " ${CONFIG_ENV_NAMES[*]-} " in *" ${name} "*) ;; *) CONFIG_ENV_NAMES+=("$name") ;; esac
  done < "$env_file"
}

secure_config_dir
load_config_env

PORT="${COLLIE_PORT:-8787}"
SOCKET="${HERDR_SOCKET_PATH:-${HOME}/.config/herdr/herdr.sock}"
# How tailscale serve exposes the bridge: "https" (default, needs a cert from the control
# server) or "http" (plain HTTP over the tailnet — use this on Headscale / .internal domains).
SERVE_MODE="${COLLIE_SERVE_MODE:-https}"
# Public HTTPS/HTTP listener and mount. Keep the bridge itself loopback-only; Tailscale Serve owns
# the public edge and strips this mount before proxying to the bridge.
BASE_PATH="${COLLIE_BASE_PATH:-/}"
if [ "$BASE_PATH" != "/" ]; then
  BASE_PATH="${BASE_PATH%/}"
  [[ "$BASE_PATH" =~ ^/([A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+$ ]] ||
    fatal "COLLIE_BASE_PATH must be / or slash-separated URL-safe path segments"
fi
case "$SERVE_MODE" in
  http) SERVE_PORT="${COLLIE_SERVE_PORT:-$PORT}" ;;
  https) SERVE_PORT="${COLLIE_SERVE_PORT:-443}" ;;
  *) fatal "COLLIE_SERVE_MODE must be http or https" ;;
esac
if ! [[ "$SERVE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$SERVE_PORT" -gt 65535 ]; then
  fatal "COLLIE_SERVE_PORT must be an integer from 1 through 65535"
fi
if [ -n "${COLLIE_UNIX_SOCKET:-}" ] && [ "${COLLIE_SKIP_SERVE:-}" != "1" ]; then
  fatal "COLLIE_UNIX_SOCKET requires COLLIE_SKIP_SERVE=1; Tailscale Serve proxies loopback TCP only"
fi
# Records the one Tailscale Serve mapping Collie published, so teardown can prove the mapping it is
# about to remove is still the one it created. Format: `<mode>:<port>|<HostPort>|<proxy>[|<path>]`.
# Root mounts retain the three-field form for compatibility with existing installations.
TAILSCALE_HANDLER_FILE="${CONFIG_DIR}/tailscale-managed-handler"
BUN="$(command -v bun || true)"
WEB_DIST="${PLUGIN_ROOT}/web/dist/index.html"

have_systemd() { command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; }
have_launchd() { [ "$(uname -s)" = "Darwin" ] && command -v launchctl >/dev/null; }

SERVE_ROUTE_FILE="${CONFIG_DIR}/serve-route"

disable_serve_route() {
  local mode="$1" port="$2" path="$3"
  local -a args=(tailscale serve)
  if [ "$mode" = "http" ]; then args+=("--http=${port}"); else args+=("--https=${port}"); fi
  [ "$path" = "/" ] || args+=("--set-path=${path}")
  "${args[@]}" off >/dev/null 2>&1 || true
}

route_targets_bridge() {
  local mode="$1" port="$2" path="$3"
  [ -n "$BUN" ] || return 1
  ROUTE_PORT="$port" ROUTE_PATH="$path" ROUTE_TARGET="http://127.0.0.1:${PORT}" "$BUN" -e '
    let json = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => { json += chunk; });
    process.stdin.on("end", () => {
      try {
        const { Web = {} } = JSON.parse(json);
        const port = process.env.ROUTE_PORT;
        const path = process.env.ROUTE_PATH;
        const target = process.env.ROUTE_TARGET;
        const found = Object.entries(Web).some(([host, config]) =>
          (host.endsWith(`:${port}`) || (port === "443" && !host.match(/:\d+$/))) &&
          config.Handlers?.[path]?.Proxy === target,
        );
        process.exit(found ? 0 : 1);
      } catch {
        process.exit(1);
      }
    });
  ' < <(tailscale serve status --json 2>/dev/null)
}

load_recorded_serve_route() {
  local extra
  RECORDED_SERVE_MODE=""
  RECORDED_SERVE_PORT=""
  RECORDED_BASE_PATH=""
  [ -e "$SERVE_ROUTE_FILE" ] || return 1
  [ -f "$SERVE_ROUTE_FILE" ] && [ ! -L "$SERVE_ROUTE_FILE" ] ||
    fatal "refusing invalid Serve route record: ${SERVE_ROUTE_FILE}"
  {
    IFS= read -r RECORDED_SERVE_MODE
    IFS= read -r RECORDED_SERVE_PORT
    IFS= read -r RECORDED_BASE_PATH
    IFS= read -r extra || true
  } < "$SERVE_ROUTE_FILE"
  [ -z "${extra:-}" ] &&
    [[ "$RECORDED_SERVE_MODE" =~ ^(http|https)$ ]] &&
    [[ "$RECORDED_SERVE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] &&
    [ "$RECORDED_SERVE_PORT" -le 65535 ] &&
    { [ "$RECORDED_BASE_PATH" = "/" ] ||
      [[ "$RECORDED_BASE_PATH" =~ ^/([A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+$ ]]; } ||
    fatal "invalid Serve route record: ${SERVE_ROUTE_FILE}"
}

record_serve_route() {
  local tmp
  tmp="$(umask 077; mktemp "${CONFIG_DIR}/.serve-route.XXXXXX")"
  printf '%s\n%s\n%s\n' "$SERVE_MODE" "$SERVE_PORT" "$BASE_PATH" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$SERVE_ROUTE_FILE"
}

remove_previous_serve_route() {
  if load_recorded_serve_route; then
    if [ "$RECORDED_SERVE_MODE" = "$SERVE_MODE" ] &&
      [ "$RECORDED_SERVE_PORT" = "$SERVE_PORT" ] &&
      [ "$RECORDED_BASE_PATH" = "$BASE_PATH" ]; then
      return
    fi
    if [ "$RECORDED_BASE_PATH" != "/" ]; then
      disable_serve_route "$RECORDED_SERVE_MODE" "$RECORDED_SERVE_PORT" "/sw.js"
    fi
    disable_serve_route "$RECORDED_SERVE_MODE" "$RECORDED_SERVE_PORT" "$RECORDED_BASE_PATH"
    rm -f "$SERVE_ROUTE_FILE"
  elif [ "$BASE_PATH" != "/" ]; then
    # Before route records, Collie served `/`. Remove it only after status JSON proves its exact
    # bridge target, including the historic default HTTPS :443 listener.
    if route_targets_bridge "$SERVE_MODE" "$SERVE_PORT" "/"; then
      disable_serve_route "$SERVE_MODE" "$SERVE_PORT" "/"
    fi
    if [ "$SERVE_MODE" != "https" ] || [ "$SERVE_PORT" != "443" ]; then
      if route_targets_bridge "https" "443" "/"; then
        disable_serve_route "https" "443" "/"
      fi
    fi
  fi
}

# A pre-mount Collie PWA registered `/sw.js` at origin scope. That worker keeps controlling
# `/collie` after the app moves under a mount, so it can serve an obsolete shell forever. Publish a
# one-shot worker at that old URL: it unregisters itself and reloads only Collie tabs. This route has
# no API or app content and remains tailnet-authenticated by Tailscale Serve.
install_legacy_root_worker_cleanup() {
  [ "$BASE_PATH" != "/" ] || return 0
  local out="${CONFIG_DIR}/serve-legacy-sw.out" tailscale_host cleanup_proxy
  tailscale_host="$(self_dnsname)"
  cleanup_proxy="http://127.0.0.1:${PORT}/__collie_legacy_root_sw_cleanup.js"
  if [ -z "$tailscale_host" ]; then
    echo "warn: cannot determine Tailscale hostname for legacy service-worker cleanup" >&2
    return 1
  fi
  ensure_tailscale_handler_available "${tailscale_host}:${SERVE_PORT}" "$SERVE_PORT" "$SERVE_MODE" \
    "/sw.js" "$cleanup_proxy" || return 1
  local -a args=(tailscale serve --bg)
  if [ "$SERVE_MODE" = "http" ]; then
    args+=("--http=${SERVE_PORT}")
  else
    args+=("--https=${SERVE_PORT}")
  fi
  args+=("--set-path=/sw.js")
  if "${args[@]}" "$cleanup_proxy" >"$out" 2>&1; then
    echo "tailscale serve legacy worker cleanup → :${SERVE_PORT}/sw.js"
  else
    echo "warn: legacy service-worker cleanup route failed:" >&2
    cat "$out" >&2
    return 1
  fi
}


# Build the Vite/React PWA into web/dist. The bridge serves that directory; without it the API
# still runs but the UI 503s. Safe to call repeatedly (no-op if already built, unless forced).
cmd_build() {
  [ -n "$BUN" ] || { echo "error: bun not found on PATH" >&2; exit 1; }
  # Version gate: refuse to build a release whose version files / CHANGELOG disagree.
  # Override (e.g. mid-refactor) with SKIP_VERSION_CHECK=1.
  if [ "${SKIP_VERSION_CHECK:-}" != "1" ]; then
    bash "${PLUGIN_ROOT}/scripts/check-version.sh"
  fi
  # Install BOTH dependency trees before typechecking. The root typecheck (tsconfig `types: ["bun"]`)
  # resolves @types/bun from the ROOT node_modules; a fresh Herdr checkout ships neither tree, so
  # without a root install the very first build dies with TS2688 "Cannot find type definition file
  # for 'bun'" and Herdr rolls the install back (issue #9). It works on the dev host only because a
  # manual `bun install` left root node_modules behind.
  ( cd "${PLUGIN_ROOT}" && "$BUN" install )
  ( cd "${PLUGIN_ROOT}/web" && "$BUN" install )
  # Typecheck BOTH sides before building — the Vite build itself does not typecheck, so a type
  # error would otherwise ship silently. Skip with SKIP_TYPECHECK=1 (same hatch as the pre-push hook).
  if [ "${SKIP_TYPECHECK:-}" != "1" ]; then
    ( cd "${PLUGIN_ROOT}" && "$BUN" run typecheck )
    ( cd "${PLUGIN_ROOT}/web" && "$BUN" run typecheck )
  fi
  # Staged build + atomic swap. Vite empties its output dir first, so building straight into web/dist
  # would leave it EMPTY with no rollback if the build failed — and the bridge serves web/dist from
  # disk at request time. Build into web/dist-staging, then swap it in only on success. `set -e`
  # aborts the function before the swap on any build failure, so a live web/dist survives untouched.
  local staging="${PLUGIN_ROOT}/web/dist-staging"
  rm -rf "$staging"
  ( cd "${PLUGIN_ROOT}/web" && "$BUN" run build -- --outDir dist-staging --emptyOutDir )
  # Swap is the LAST step (a near-atomic same-filesystem rename) so the served dir is never half-built.
  rm -rf "${PLUGIN_ROOT}/web/dist"
  mv "$staging" "${PLUGIN_ROOT}/web/dist"
}

configured_build_base_path() {
  if [ "$BASE_PATH" = "/" ]; then echo "/"; else echo "${BASE_PATH}/"; fi
}

built_base_path() {
  sed -n 's/.*"basePath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "${PLUGIN_ROOT}/web/dist/build-info.json" | head -1
}

ensure_build() {
  if [ -f "$WEB_DIST" ] && [ "$(built_base_path)" = "$(configured_build_base_path)" ]; then return 0; fi
  [ -n "$BUN" ] || { echo "note: bun not found; cannot build web UI" >&2; return 1; }
  echo "building web UI (first run or public mount changed)…"
  cmd_build || { echo "warn: web build failed; API will run but the UI will 503 until built" >&2; return 1; }
}

self_dnsname() {
  tailscale status --json 2>/dev/null | bun -e \
    "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>{try{process.stdout.write(JSON.parse(d).Self.DNSName.replace(/\.\$/,''))}catch{}})"
}

bridge_url() {
  local name origin
  name="$(self_dnsname)"
  if [ -z "$name" ]; then echo "http://127.0.0.1:${PORT} (Tailscale name unavailable)"; return; fi
  if [ "$SERVE_MODE" = "http" ]; then
    origin="http://${name}:${SERVE_PORT}"
  elif [ "$SERVE_PORT" = "443" ]; then
    origin="https://${name}"
  else
    origin="https://${name}:${SERVE_PORT}"
  fi
  echo "${origin}${BASE_PATH}"
}

# The version Collie is actually serving — read from the built bundle's stamp
# (web/dist/build-info.json, the same id the PWA footer and /api/config report), e.g. "0.16.0+3441656".
# Falls back to the manifest version (tagged "web not built") when web/dist doesn't exist yet. This is
# the authoritative "what's running", unlike Herdr's registry value which is cached at link time.
collie_version() {
  local bi="${PLUGIN_ROOT}/web/dist/build-info.json" v sha
  if [ -f "$bi" ]; then
    v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$bi" | head -1)"
    sha="$(sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$bi" | head -1)"
    if [ -n "$v" ]; then [ -n "$sha" ] && echo "${v}+${sha}" || echo "$v"; return; fi
  fi
  v="$(sed -n 's/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${PLUGIN_ROOT}/herdr-plugin.toml" | head -1)"
  [ -n "$v" ] && echo "${v} (manifest; web not built)" || echo "unknown"
}

# True once the bridge accepts a TCP connection on its loopback port — i.e. the HTTP server is
# actually up, not merely that the unit went "active". Uses bash's /dev/tcp (no curl dependency);
# polls for up to ~5s to cover a just-launched service still binding.
bridge_ready() {
  local i
  for i in $(seq 1 25); do
    # Open the probe socket on fd 3, then close both directions so the fd never leaks. `&&` (not `;`)
    # is load-bearing: a refused connection must short-circuit, else the trailing close would mask it.
    if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}" && exec 3>&- 3<&-) 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

# One scannable "is Collie up?" summary — readiness, how it's supervised, and both URLs. Shared by
# `start` (post-launch confirmation) and `status` (on demand) so the two always agree.
print_status_banner() {
  local svc
  if have_systemd; then
    svc="systemd --user (${UNIT}) · $(systemctl --user is-active "$UNIT" 2>/dev/null || echo unknown)"
  elif have_launchd; then
    if launchctl print "gui/${USER_UID}/${LAUNCHD_LABEL}" >/dev/null 2>&1; then
      svc="launchd (${LAUNCHD_LABEL}) · loaded"
    else
      svc="launchd (${LAUNCHD_LABEL}) · not loaded"
    fi
  elif [ -f "${CONFIG_DIR}/collie.pid" ]; then
    svc="pid $(cat "${CONFIG_DIR}/collie.pid" 2>/dev/null) (no supervisor)"
  else
    svc="not supervised"
  fi
  local ver; ver="$(collie_version)"
  echo
  if bridge_ready; then
    echo "  ✓ Collie is running  ·  v${ver}"
  else
    echo "  ⚠ Collie isn't answering on :${PORT} yet (v${ver}) — check 'collie-ctl.sh logs'"
  fi
  echo "    service   ${svc}"
  echo "    local     http://127.0.0.1:${PORT}"
  if [ "${COLLIE_SKIP_SERVE:-}" = "1" ]; then
    if [ -n "${COLLIE_PUBLIC_URL:-}" ]; then
      echo "    proxy     ${COLLIE_PUBLIC_URL}"
    else
      echo "    proxy     (COLLIE_SKIP_SERVE=1 — set COLLIE_PUBLIC_URL to your reverse-proxy URL)"
    fi
  else
    echo "    tailnet   $(bridge_url)"
  fi
  echo
}

write_unit() {
  [ -n "$BUN" ] || { echo "error: bun not found on PATH" >&2; exit 1; }
  mkdir -p "$(dirname "$UNIT_FILE")" "$CONFIG_DIR"
  cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Collie
After=default.target
# Never give up restarting — a phone-only operator can't run 'systemctl reset-failed'.
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${PLUGIN_ROOT}
ExecStart=${BUN} run ${PLUGIN_ROOT}/bridge/index.ts
Restart=on-failure
RestartSec=5
# Hardening: the bridge is remote shell access, so deny privilege escalation and give it a private
# /tmp. ProtectSystem is intentionally NOT set — the only write path is the env-driven state dir,
# which Herdr may inject to an arbitrary location, so it can't be enumerated in a static ReadWritePaths.
NoNewPrivileges=yes
PrivateTmp=yes
Environment=HERDR_SOCKET_PATH=${SOCKET}
Environment=COLLIE_PORT=${PORT}
Environment=HERDR_PLUGIN_CONFIG_DIR=${CONFIG_DIR}
EnvironmentFile=-${CONFIG_DIR}/.env

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
}

xml_escape() {
  local value="$1"
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  value=${value//\"/\&quot;}
  value=${value//\'/\&apos;}
  printf '%s' "$value"
}

write_launch_agent() {
  local launch_dir tmp name
  [ -n "$BUN" ] || fatal "bun not found on PATH"
  [ ! -L "$CONFIG_DIR" ] || fatal "refusing symlinked config directory: ${CONFIG_DIR}"
  mkdir -p "$CONFIG_DIR" "${HOME}/Library/LaunchAgents"
  [ "$(file_uid "$CONFIG_DIR")" = "$USER_UID" ] || fatal "${CONFIG_DIR} must be owned by uid ${USER_UID}"
  chmod 700 "$CONFIG_DIR" || fatal "could not restrict ${CONFIG_DIR} to owner-only access"
  launch_dir="$(dirname "$LAUNCHD_PLIST")"
  tmp="$(umask 077; mktemp "${launch_dir}/${LAUNCHD_LABEL}.plist.XXXXXX")"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml_escape "$LAUNCHD_LABEL")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$BUN")</string>
    <string>run</string>
    <string>$(xml_escape "${PLUGIN_ROOT}/bridge/index.ts")</string>
  </array>
  <key>WorkingDirectory</key><string>$(xml_escape "$PLUGIN_ROOT")</string>
  <key>EnvironmentVariables</key>
  <dict>
EOF
    for name in "${CONFIG_ENV_NAMES[@]}"; do
      case "$name" in HERDR_SOCKET_PATH|COLLIE_PORT) continue ;; esac
      printf '    <key>%s</key><string>%s</string>\n' "$(xml_escape "$name")" "$(xml_escape "${!name}")"
    done
    cat <<EOF
    <key>HERDR_SOCKET_PATH</key><string>$(xml_escape "$SOCKET")</string>
    <key>COLLIE_PORT</key><string>$(xml_escape "$PORT")</string>
    <key>HERDR_PLUGIN_CONFIG_DIR</key><string>$(xml_escape "$CONFIG_DIR")</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>ProcessType</key><string>Background</string>
  <key>Umask</key><integer>63</integer>
  <key>StandardOutPath</key><string>$(xml_escape "${CONFIG_DIR}/collie.log")</string>
  <key>StandardErrorPath</key><string>$(xml_escape "${CONFIG_DIR}/collie.log")</string>
</dict>
</plist>
EOF
  } > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$LAUNCHD_PLIST"
}

start_launch_agent() {
  local target="gui/${USER_UID}/${LAUNCHD_LABEL}"
  write_launch_agent
  launchctl bootout "$target" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${USER_UID}" "$LAUNCHD_PLIST"
  launchctl kickstart -k "$target"
}

cmd_start() {
  ensure_build || true
  if have_systemd; then
    write_unit
    systemctl --user enable --now "$UNIT"
    echo "bridge started (systemd --user: ${UNIT})"
  elif have_launchd; then
    start_launch_agent
    echo "bridge started (launchd: ${LAUNCHD_LABEL})"
  else
    # Last-resort fallback for platforms without a user-service manager. It is intentionally not
    # advertised as durable: use a native supervisor when restart/login autoload matters.
    mkdir -p "$CONFIG_DIR"
    [ -n "$BUN" ] || { echo "error: bun not found" >&2; exit 1; }
    HERDR_SOCKET_PATH="$SOCKET" COLLIE_PORT="$PORT" HERDR_PLUGIN_CONFIG_DIR="$CONFIG_DIR" \
      nohup "$BUN" run "${PLUGIN_ROOT}/bridge/index.ts" >>"${CONFIG_DIR}/collie.log" 2>&1 &
    echo $! > "${CONFIG_DIR}/collie.pid"
    echo "bridge started (pid $(cat "${CONFIG_DIR}/collie.pid"), no supervisor)"
  fi
  # A front door that won't come up must not abort `start`. The bridge is already running on
  # loopback, and the banner is what the README's troubleshooting flow tells people to read — under
  # `set -e` a bare `cmd_serve` would exit here and print nothing. cmd_serve reports its own reason.
  cmd_serve || echo "note: the tailnet front door did not come up; the bridge is still on 127.0.0.1:${PORT}" >&2
  print_status_banner
}

cmd_stop() {
  if have_systemd; then
    systemctl --user disable --now "$UNIT" 2>/dev/null || true
  elif have_launchd; then
    launchctl bootout "gui/${USER_UID}/${LAUNCHD_LABEL}" 2>/dev/null || true
    rm -f "$LAUNCHD_PLIST"
  elif [ -f "${CONFIG_DIR}/collie.pid" ]; then
    kill "$(cat "${CONFIG_DIR}/collie.pid")" 2>/dev/null || true
    rm -f "${CONFIG_DIR}/collie.pid"
  fi
  echo "bridge stopped"
}

cmd_restart() { cmd_stop; cmd_start; }

# Tear the service down completely (the inverse of `start`): stop + disable it, remove the
# systemd --user unit, remove Collie's tailscale serve mapping, and drop the pidfile. Deliberately leaves your
# config (${CONFIG_DIR}/.env) and the on-disk checkout in place — `uninstall` removes only what
# `start` created. To remove the plugin registration too, run `herdr plugin uninstall herdr.collie`
# (or, for a linked clone, just delete the checkout).
cmd_uninstall() {
  cmd_stop
  cmd_unserve
  if have_systemd; then
    rm -f "$UNIT_FILE"
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user reset-failed "$UNIT" 2>/dev/null || true
  elif have_launchd; then
    rm -f "$LAUNCHD_PLIST"
  fi
  rm -f "${CONFIG_DIR}/collie.pid"
  echo "✓ uninstalled: service stopped & disabled, systemd unit removed, Collie's tailscale serve mapping removed"
  echo "  kept: ${CONFIG_DIR}/.env and the checkout — delete those to remove every trace"
}

# Update to the latest release. Collie is a link-mode Herdr plugin, so the checkout on disk IS the
# plugin (Herdr has no `plugin update`) — this is the turnkey refresh: pull, rebuild the UI, restart
# the backend. The pull can rewrite THIS script, and bash reads scripts by byte offset, so we re-exec
# the freshly-pulled copy (via the internal `_apply-update` step) to run build + restart.
cmd_update() {
  echo "updating Collie (git pull --ff-only)…"
  git -C "$PLUGIN_ROOT" pull --ff-only
  exec bash "${PLUGIN_ROOT}/scripts/collie-ctl.sh" _apply-update
}

# After an update, Herdr's plugin registry still has the action set + version CACHED from the last
# `plugin link` — so a newly added action (e.g. `version`) returns `plugin_action_not_found`, and
# `herdr plugin list` shows the old version, until a re-link. Re-link here so `update` self-heals it.
# Best-effort: never fails the update (Herdr may be down, or this may be a non-link install) — it just
# prints how to do it by hand.
refresh_registry() {
  command -v herdr >/dev/null || return 0
  if herdr plugin link "$PLUGIN_ROOT" >/dev/null 2>&1; then
    echo "herdr registry refreshed (re-linked) — new actions are invokable now"
  else
    echo "note: couldn't refresh the Herdr registry (is the Herdr server running?) —"
    echo "      run: herdr plugin link \"$PLUGIN_ROOT\""
  fi
}

# Second half of `update`, run from the just-pulled script. cmd_build re-runs the version gate (a
# half-bumped release can't go live) and rebuilds web/dist; cmd_restart picks up any bridge/ changes;
# refresh_registry re-links so Herdr learns any newly added actions / the new version.
cmd_apply_update() {
  cmd_build
  cmd_restart
  refresh_registry
  echo "✓ update complete"
}

# `tailscale serve … off` for one handler, treating "already gone" as success so teardown is
# idempotent. Any other failure is real and must not be swallowed.
remove_tailscale_handler() {
  local description="$1" output
  shift
  if output="$(tailscale serve "$@" off 2>&1)"; then
    return 0
  fi
  case "$output" in
    *"handler does not exist"*) return 0 ;;
  esac
  [ -z "$output" ] || printf '%s\n' "$output" >&2
  echo "error: failed to remove Collie's ${description} mapping" >&2
  return 1
}

# Identify the exact handler we recorded: "absent", or "<protocol>|proxy:<target>".
# The path is part of the identity — a mount must never be mistaken for the listener root.
tailscale_handler_fingerprint() {
  local host_port="$1" port="$2" path="$3" status_json result
  [ -n "$BUN" ] || return 1
  status_json="$(tailscale serve status --json 2>/dev/null)" || return 1
  result="$(
    printf '%s' "$status_json" |
      COLLIE_SERVE_HOST_PORT="$host_port" COLLIE_SERVE_PORT="$port" COLLIE_SERVE_PATH="$path" "$BUN" -e '
        let data = "";
        process.stdin.on("data", chunk => data += chunk).on("end", () => {
          try {
            const config = JSON.parse(data || "{}");
            const hostPort = process.env.COLLIE_SERVE_HOST_PORT;
            const port = process.env.COLLIE_SERVE_PORT;
            const path = process.env.COLLIE_SERVE_PATH;
            const handlers = config?.Web?.[hostPort]?.Handlers ?? {};
            if (!Object.prototype.hasOwnProperty.call(handlers, path)) {
              process.stdout.write("absent");
              return;
            }
            const listener = config?.TCP?.[port];
            const protocol = listener?.HTTP === true ? "http" :
              listener?.HTTPS === true ? "https" : "other";
            const proxy = handlers[path]?.Proxy;
            process.stdout.write(typeof proxy === "string" && proxy ?
              `${protocol}|proxy:${proxy}` : `${protocol}|other`);
          } catch {
            process.exitCode = 2;
          }
        });
      '
  )" || return 1
  printf '%s\n' "$result"
}

# A pre-mount deployment may have left Collie's self-unregistering service worker at `/sw.js`.
# Remove it only when its exact proxy target proves it is ours; another app may legitimately own
# that path on the same listener.
remove_legacy_root_worker_cleanup() {
  local mode="$1" port="$2" host_port="$3" path="$4" fingerprint expected_proxy
  [ "$path" != "/" ] || return 0
  expected_proxy="http://127.0.0.1:${PORT}/__collie_legacy_root_sw_cleanup.js"
  if ! fingerprint="$(tailscale_handler_fingerprint "$host_port" "$port" "/sw.js")"; then
    echo "warn: cannot inspect Collie's legacy service-worker cleanup mapping; leaving it intact" >&2
    return 0
  fi
  [ "$fingerprint" = "absent" ] && return 0
  if [ "$fingerprint" != "${mode}|proxy:${expected_proxy}" ]; then
    echo "warn: /sw.js is not Collie's legacy cleanup mapping; leaving it intact" >&2
    return 0
  fi
  remove_tailscale_handler "legacy service-worker cleanup" "--${mode}=${port}" --set-path=/sw.js
}

# Remove ONLY the mapping Collie recorded as its own — never a blanket `tailscale serve reset`, and
# never a blind listener-wide `off`. If the recorded handler has been replaced, retain the record:
# a wrong removal here silently unpublishes somebody else's service.
stop_tailscale_serve() {
  local managed_state="" managed_handler="" managed_mode="" managed_port="" managed_path="/"
  local managed_host_port="" managed_proxy="" extra="" current_fingerprint=""
  if [ -f "$TAILSCALE_HANDLER_FILE" ]; then
    managed_state="$(cat "$TAILSCALE_HANDLER_FILE" 2>/dev/null || true)"
    IFS='|' read -r managed_handler managed_host_port managed_proxy managed_path extra <<< "$managed_state"
    [ -n "$managed_path" ] || managed_path="/"
    case "$managed_handler" in
      http:*|https:*)
        managed_mode="${managed_handler%%:*}"
        managed_port="${managed_handler#*:}"
        case "$managed_port" in
          ''|*[!0-9]*|0) managed_mode="" ;;
        esac
        ;;
    esac
    if [ -z "$managed_mode" ] || [ "$managed_port" -gt 65535 ] ||
      [ -z "$managed_host_port" ] || [ -z "$managed_proxy" ] || [ -n "$extra" ] ||
      { [ "$managed_path" != "/" ] &&
        ! [[ "$managed_path" =~ ^/([A-Za-z0-9._~-]+/)*[A-Za-z0-9._~-]+$ ]]; }; then
      echo "error: invalid managed Tailscale handler state: ${managed_state}" >&2
      return 1
    fi
    case "$managed_host_port" in
      *":${managed_port}") ;;
      *)
        echo "error: managed Tailscale HostPort does not match its listener: ${managed_state}" >&2
        return 1
        ;;
    esac
    case "$managed_proxy" in
      http://127.0.0.1:[0-9]*) ;;
      *)
        echo "error: invalid managed Tailscale proxy target: ${managed_state}" >&2
        return 1
        ;;
    esac
  else
    echo "tailscale serve: no Collie-managed mapping recorded"
    return 0
  fi
  if ! command -v tailscale >/dev/null; then
    echo "error: tailscale not found; retained the managed ${managed_handler} state for retry" >&2
    return 1
  fi
  if ! current_fingerprint="$(tailscale_handler_fingerprint "$managed_host_port" "$managed_port" "$managed_path")"; then
    echo "error: cannot inspect the managed Tailscale handler; retained ownership state" >&2
    return 1
  fi
  if [ "$current_fingerprint" = "absent" ]; then
    remove_legacy_root_worker_cleanup "$managed_mode" "$managed_port" "$managed_host_port" "$managed_path"
    if ! rm -f "$TAILSCALE_HANDLER_FILE"; then
      echo "error: managed Tailscale handler is absent but ownership state could not be removed" >&2
      return 1
    fi
    echo "tailscale serve: managed handler is already absent; cleared stale ownership state"
    return 0
  fi
  if [ "$current_fingerprint" != "${managed_mode}|proxy:${managed_proxy}" ]; then
    echo "error: managed Tailscale handler was replaced; refusing to remove the current mapping" >&2
    return 1
  fi
  remove_legacy_root_worker_cleanup "$managed_mode" "$managed_port" "$managed_host_port" "$managed_path"
  remove_tailscale_handler "Serve :${managed_port}${managed_path} mount" \
    "--${managed_mode}=${managed_port}" "--set-path=${managed_path}" || {
    echo "error: managed ingress cleanup incomplete; retained ${TAILSCALE_HANDLER_FILE} for retry" >&2
    return 1
  }
  if ! rm -f "$TAILSCALE_HANDLER_FILE"; then
    echo "error: Tailscale handler was removed but ownership state could not be removed" >&2
    return 1
  fi
  echo "tailscale serve: removed Collie's managed ${managed_handler}${managed_path} mapping"
}

# Refuse to publish over a handler we do not own. The mount path is part of the ownership check, so
# unrelated Serve routes may coexist on the same listener without Collie replacing or removing them.
# A pre-ownership handler that already proxies to this bridge is adopted; foreground Serve sessions
# are never adopted because they belong to a live process that is not us.
ensure_tailscale_handler_available() {
  local host_port="$1" port="$2" protocol="$3" path="$4" expected_proxy="$5" status_json result
  [ -n "$BUN" ] || {
    echo "error: bun is required to inspect Tailscale Serve ownership before publishing" >&2
    return 1
  }
  if ! status_json="$(tailscale serve status --json 2>/dev/null)"; then
    echo "error: cannot inspect Tailscale Serve status; refusing to overwrite ${path} on :${port}" >&2
    return 1
  fi
  if ! result="$(
    printf '%s' "$status_json" |
      COLLIE_SERVE_HOST_PORT="$host_port" COLLIE_SERVE_PORT="$port" COLLIE_SERVE_PROTOCOL="$protocol" \
      COLLIE_SERVE_PATH="$path" COLLIE_SERVE_EXPECTED_PROXY="$expected_proxy" "$BUN" -e '
        let data = "";
        process.stdin.on("data", chunk => data += chunk).on("end", () => {
          try {
            const config = JSON.parse(data || "{}");
            const hostPort = process.env.COLLIE_SERVE_HOST_PORT;
            const port = process.env.COLLIE_SERVE_PORT;
            const protocol = process.env.COLLIE_SERVE_PROTOCOL;
            const path = process.env.COLLIE_SERVE_PATH;
            const expectedProxy = process.env.COLLIE_SERVE_EXPECTED_PROXY;
            const targetsAt = serveConfig => {
              const handlers = serveConfig?.Web?.[hostPort]?.Handlers ?? {};
              return Object.prototype.hasOwnProperty.call(handlers, path) ? [handlers[path]?.Proxy] : [];
            };
            const foregroundTargets = serveConfig =>
              Object.values(serveConfig?.Foreground ?? {})
                .flatMap(fg => targetsAt(fg).concat(foregroundTargets(fg)));
            const hasProtocolMismatch = serveConfig => {
              const listener = serveConfig?.TCP?.[port];
              const mismatch = listener !== undefined &&
                (protocol === "http" ? listener?.HTTP !== true : listener?.HTTPS !== true);
              return mismatch ||
                Object.values(serveConfig?.Foreground ?? {}).some(hasProtocolMismatch);
            };
            if (hasProtocolMismatch(config)) {
              process.stdout.write("protocol-mismatch");
              return;
            }
            if (foregroundTargets(config).length > 0) {
              process.stdout.write("occupied");
              return;
            }
            const targets = targetsAt(config);
            if (targets.length === 0) {
              process.stdout.write("free");
              return;
            }
            process.stdout.write(
              targets.every(target => target === expectedProxy) ? "adoptable" : "occupied");
          } catch {
            process.exitCode = 2;
          }
        });
      '
  )"; then
    echo "error: invalid Tailscale Serve status; refusing to overwrite ${path} on :${port}" >&2
    return 1
  fi
  if [ "$result" = "protocol-mismatch" ]; then
    echo "error: Tailscale Serve :${port} already uses the opposite listener protocol" >&2
    return 1
  fi
  if [ "$result" = "occupied" ]; then
    echo "error: Tailscale Serve already has an unowned ${path} mount on :${port}; refusing to overwrite it" >&2
    return 1
  fi
  if [ "$result" = "adoptable" ]; then
    echo "tailscale serve: adopting the existing Collie ${path} mount on :${port}"
  fi
}

cmd_serve() {
  if [ "${COLLIE_SKIP_SERVE:-}" = "1" ]; then
    # Still tear down: skipping teardown would strand a mapping published before the flag was
    # flipped on, leaving the app reachable by a path the operator thinks is closed.
    stop_tailscale_serve || return 1
    echo "tailscale serve skipped (COLLIE_SKIP_SERVE=1) — bridge is on 127.0.0.1:${PORT} only"
    return
  fi
  if [ -e "$TAILSCALE_HANDLER_FILE" ]; then
    stop_tailscale_serve || return 1
  else
    # Migrate the pre-ownership route record once. New installs use the verified handler record.
    remove_previous_serve_route
  fi
  command -v tailscale >/dev/null || {
    echo "error: tailscale not found; cannot publish the tailnet front door" >&2
    return 1
  }
  local tailscale_host; tailscale_host="$(self_dnsname)"
  if [ -z "$tailscale_host" ]; then
    echo "error: cannot determine Tailscale hostname; refusing to publish an untrackable Serve mapping" >&2
    return 1
  fi
  local tailscale_host_port="${tailscale_host}:${SERVE_PORT}"
  local expected_proxy="http://127.0.0.1:${PORT}"
  local out="${CONFIG_DIR}/serve.out"
  local -a args=(tailscale serve --bg)
  if [ "$SERVE_MODE" = "http" ]; then
    args+=("--http=${SERVE_PORT}")
  else
    args+=("--https=${SERVE_PORT}")
  fi
  ensure_tailscale_handler_available "$tailscale_host_port" "$SERVE_PORT" "$SERVE_MODE" "$BASE_PATH" "$expected_proxy" || return 1
  if [ "$BASE_PATH" = "/" ]; then
    printf '%s|%s|%s\n' "${SERVE_MODE}:${SERVE_PORT}" "$tailscale_host_port" "$expected_proxy" > "$TAILSCALE_HANDLER_FILE"
  else
    printf '%s|%s|%s|%s\n' "${SERVE_MODE}:${SERVE_PORT}" "$tailscale_host_port" "$expected_proxy" "$BASE_PATH" > "$TAILSCALE_HANDLER_FILE"
  fi
  [ "$BASE_PATH" = "/" ] || args+=("--set-path=${BASE_PATH}")
  if "${args[@]}" "$PORT" >"$out" 2>&1; then
    # Handler ownership replaces the legacy route record after the first verified publication.
    rm -f "$SERVE_ROUTE_FILE"
    install_legacy_root_worker_cleanup || true
    echo "tailscale serve (${SERVE_MODE}) → tailnet :${SERVE_PORT}${BASE_PATH} -> 127.0.0.1:${PORT}"
  else
    rm -f "$TAILSCALE_HANDLER_FILE"
    echo "note: tailscale serve failed (try 'sudo tailscale set --operator=\$USER'):"
    cat "$out"
    return 1
  fi
}

# Remove only a verified handler Collie recorded. For pre-ownership installations, use the old
# route record as the migration authority; never reset a listener or guess at an unrecorded mapping.
cmd_unserve() {
  if [ -e "$TAILSCALE_HANDLER_FILE" ]; then
    stop_tailscale_serve
    return
  fi
  command -v tailscale >/dev/null || { echo "note: tailscale not found; no serve mapping to remove"; return; }
  if ! load_recorded_serve_route; then
    echo "tailscale serve: no Collie-managed mapping recorded"
    return
  fi
  if [ "$RECORDED_BASE_PATH" != "/" ]; then
    disable_serve_route "$RECORDED_SERVE_MODE" "$RECORDED_SERVE_PORT" "/sw.js"
  fi
  disable_serve_route "$RECORDED_SERVE_MODE" "$RECORDED_SERVE_PORT" "$RECORDED_BASE_PATH"
  rm -f "$SERVE_ROUTE_FILE"
  echo "tailscale serve: removed Collie's ${RECORDED_SERVE_MODE} :${RECORDED_SERVE_PORT}${RECORDED_BASE_PATH} mapping"
}

cmd_status() {
  print_status_banner
  if [ "${COLLIE_SKIP_SERVE:-}" = "1" ]; then
    echo "  serve config: skipped (COLLIE_SKIP_SERVE=1)"
  else
    echo "  serve config:"; tailscale serve status 2>/dev/null | sed 's/^/    /' || true
  fi
}

cmd_logs() {
  if have_systemd; then journalctl --user -u "$UNIT" -n "${1:-50}" --no-pager
  else tail -n "${1:-50}" "${CONFIG_DIR}/collie.log" 2>/dev/null || echo "(no log)"; fi
}

cmd_version() { collie_version; }

# Fire a one-off Web Push to every subscribed device — verify push end-to-end without waiting for an
# agent to actually block. Delegates to scripts/push-test.ts; the constrained .env loader above
# supplies its VAPID keys. Args: [title] [body] [paneId].
cmd_push_test() {
  [ -n "$BUN" ] || { echo "error: bun not found on PATH" >&2; exit 1; }
  "$BUN" run "${PLUGIN_ROOT}/scripts/push-test.ts" "$@"
}

# Sourced (by scripts/collie-ctl.test.sh) rather than run: define the functions and stop before the
# dispatch, so a test can call one function in isolation with its dependencies stubbed out.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

case "${1:-}" in
  start)   cmd_start ;;
  stop)    cmd_stop ;;
  restart) cmd_restart ;;
  uninstall) cmd_uninstall ;;
  update)  cmd_update ;;
  _apply-update) cmd_apply_update ;;  # internal: second half of `update`, run post-pull
  build)   cmd_build ;;
  serve)   cmd_serve; echo "open: $(bridge_url)" ;;
  unserve) cmd_unserve ;;
  status)  cmd_status ;;
  url)     bridge_url ;;
  version) cmd_version ;;
  push-test) shift || true; cmd_push_test "$@" ;;
  logs)    cmd_logs "${2:-50}" ;;
  *) echo "usage: collie-ctl.sh {start|stop|restart|uninstall|update|version|push-test|build|serve|unserve|status|url|logs}" >&2; exit 2 ;;
esac
