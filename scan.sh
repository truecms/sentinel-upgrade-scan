#!/usr/bin/env bash
# Sentinel upgrade scan.
#
# Runs the Drupal Upgrade Status scan inside the site's own image, beside a
# copy of its database, and sends the result to Sentinel. Only counts and a
# reason from a fixed list leave the runner. The scan key is never printed.
#
# Settings (environment):
#   SENTINEL_UPGRADE_SCAN   Must be set (and not 0 or false), or nothing runs.
#   SENTINEL_SITE_UUID      The site's UUID in Sentinel.
#   SENTINEL_SCAN_KEY       The site's scan key (sk_scan_...). Keep it secret.
#   SENTINEL_API_URL        Optional. Sentinel API base URL. Default: the
#                           connector's own setting, else
#                           https://ingest.sentinelconnector.io.
#   SENTINEL_PROJECT_DIR    Optional. The Composer project root. Default: the
#                           current directory.
#   SENTINEL_DRUSH          Optional. The Drush command. Default:
#                           vendor/bin/drush, else drush on the PATH.
#
# Exit codes: 0 done, or skipped on purpose (switch off, no database, scan
# route closed). 1 a real fault, already reported to Sentinel where possible.

set -uo pipefail

readonly MIN_CONNECTOR_VERSION='1.6.0'
readonly DEFAULT_API_URL='https://ingest.sentinelconnector.io'

log() { printf 'Sentinel upgrade scan: %s\n' "$*"; }
fail() { log "$*" >&2; exit 1; }

case "${SENTINEL_UPGRADE_SCAN:-}" in
  ''|0|false|FALSE|no|off)
    log 'SENTINEL_UPGRADE_SCAN is not set. Nothing to do.'
    exit 0
    ;;
esac

uuid="${SENTINEL_SITE_UUID:-}"
key="${SENTINEL_SCAN_KEY:-}"
uuid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
[[ "$uuid" =~ $uuid_re ]] || fail 'SENTINEL_SITE_UUID is missing or is not a UUID. Copy it from the site page in Sentinel.'
[[ "$key" =~ ^sk_scan_[0-9a-f]{64}$ ]] || fail 'SENTINEL_SCAN_KEY is missing or is not a scan key. Create one on the site page in Sentinel and store it as a secret.'

# Plain http:// only for localhost, as in the connector: the key must not
# cross a network in the clear.
valid_url() {
  [[ "$1" =~ ^https://[^/[:space:]]+$ || "$1" =~ ^http://(localhost|[^/:[:space:]]+\.localhost)(:[0-9]+)?$ ]]
}
api_given="${SENTINEL_API_URL:-${SENTINEL_CONNECTOR_API_BASE_URL:-}}"
api="${api_given:-$DEFAULT_API_URL}"
api="${api%/}"
valid_url "$api" || fail 'SENTINEL_API_URL must be a base URL with no path, such as https://ingest.sentinelconnector.io. Plain http:// is allowed only for localhost.'

cd "${SENTINEL_PROJECT_DIR:-.}" || fail 'SENTINEL_PROJECT_DIR does not exist.'

if [[ -n "${SENTINEL_DRUSH:-}" ]]; then
  read -r -a drush <<< "$SENTINEL_DRUSH"
elif [[ -x vendor/bin/drush ]]; then
  drush=(vendor/bin/drush)
else
  drush=(drush)
fi
# An absolute path, so Drush still runs after moving to the Composer root.
if [[ "${drush[0]}" == */* && -e "${drush[0]}" ]]; then
  drush[0]="$(cd "$(dirname "${drush[0]}")" && pwd)/$(basename "${drush[0]}")"
fi
"${drush[@]}" version > /dev/null 2>&1 || fail "Drush does not run here (${drush[0]}). Set working-directory (SENTINEL_PROJECT_DIR) to your site's project folder in the image, or set drush (SENTINEL_DRUSH)."

started="$(date +%s)"
started_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
work="$(mktemp -d)"
chmod 700 "$work"

# The key goes to curl in a header file, never on the command line.
printf 'X-Scan-Key: %s\n' "$key" > "$work/header"
chmod 600 "$work/header"

restore() {
  if [[ -f "$work/modules_before" && ! -f "$work/added_modules" ]]; then
    enabled_modules | comm -13 "$work/modules_before" - > "$work/added_modules"
  fi
  if [[ -s "$work/added_modules" ]]; then
    # shellcheck disable=SC2046 # One module name per line.
    if "${drush[@]}" pm:uninstall $(cat "$work/added_modules") --yes > /dev/null 2>&1; then
      log 'Uninstalled the modules added for the scan.'
    else
      log 'Could not uninstall the modules added for the scan. Do not reuse this database copy.'
    fi
  fi
  if [[ -f "$work/composer.json" ]]; then
    cp "$work/composer.json" composer.json
    if [[ -f "$work/composer.lock" ]]; then
      cp "$work/composer.lock" composer.lock
    fi
    log 'Restored composer.json and composer.lock. Nothing is committed.'
  fi
  rm -rf "$work"
}
trap restore EXIT

# Tells Sentinel why there is no result. Prints what Sentinel answered.
# Returns 0 when Sentinel stored it or the scan route is closed.
report_problem() {
  local reason="$1" status
  if ! command -v curl > /dev/null 2>&1; then
    log "curl is not in the image, so Sentinel was not told: $reason."
    return 1
  fi
  printf '{"problem":{"reason":"%s","generated_at":"%s"}}' "$reason" "$started_iso" > "$work/body"
  status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 --proto '=https,http' \
    -X POST -H 'Content-Type: application/json' -H "@$work/header" \
    --data-binary "@$work/body" \
    "$api/api/v1/sites/$uuid/upgrade-readiness/scan" 2> /dev/null)" || status='000'
  case "$status" in
    2??) log "Sentinel shows this on the site: $reason."; return 0 ;;
    404) log 'The scan route is closed on this Sentinel. Nothing was sent.'; return 0 ;;
    401) log 'Sentinel refused the scan key. Create a new key on the site page.' ;;
    409) log 'Sentinel has no report from this site yet. Connect the site first.' ;;
    429) log 'Sentinel is limiting scan reports for this site. Try again later.' ;;
    000) log "Could not reach $api." ;;
    *) log "Sentinel answered $status." ;;
  esac
  return 1
}

# 1. A working Drupal with its database.
bootstrap="$("${drush[@]}" status --field=bootstrap 2> /dev/null | tr -d '[:space:]')" || bootstrap=''
if [[ "$bootstrap" != 'Successful' ]]; then
  log 'Drupal has no working database here, so there is nothing to scan.'
  report_problem no_database || true
  exit 0
fi

# Composer work happens in the project root, found from Drupal when the
# current folder is not it.
if [[ ! -f composer.json ]]; then
  dir="$("${drush[@]}" status --field=root 2> /dev/null | tr -d '[:space:]')"
  while [[ -n "$dir" && "$dir" != / && ! -f "$dir/composer.json" ]]; do
    dir="$(dirname "$dir")"
  done
  if [[ -n "$dir" && -f "$dir/composer.json" ]]; then
    cd "$dir" || fail "Cannot open $dir."
  fi
fi

# 2. The connector, new enough to send a scan report.
connector="$("${drush[@]}" php:eval '
  if (\Drupal::moduleHandler()->moduleExists("sentinel_connector") && class_exists("Drupal\\sentinel_connector\\PayloadBuilder")) {
    echo \Drupal\sentinel_connector\PayloadBuilder::CONNECTOR_VERSION;
  }' 2> /dev/null | tr -d '[:space:]')" || connector=''
# shellcheck disable=SC2016 # PHP code, expanded by PHP.
if [[ -z "$connector" ]] || ! php -r 'exit(version_compare($argv[1], $argv[2], ">=") ? 0 : 1);' "$connector" "$MIN_CONNECTOR_VERSION"; then
  log "The Sentinel Connector module must be enabled at version $MIN_CONNECTOR_VERSION or later (found: ${connector:-none})."
  report_problem connector_outdated || true
  exit 1
fi

# Problem reports go where the connector sends results, unless a URL was given.
if [[ -z "$api_given" ]]; then
  # shellcheck disable=SC2016 # PHP code.
  resolved="$("${drush[@]}" php:eval 'echo \Drupal::service("Drupal\\sentinel_connector\\ApiBaseUrlResolver")->getUrl() ?? "";' 2> /dev/null | tr -d '[:space:]')" || resolved=''
  resolved="${resolved%/}"
  if [[ -n "$resolved" ]] && valid_url "$resolved"; then
    api="$resolved"
  fi
fi

# 3. Upgrade Status, added for this run only.
present="$("${drush[@]}" php:eval 'echo \Drupal::service("extension.list.module")->exists("upgrade_status") ? "yes" : "no";' 2> /dev/null | tr -d '[:space:]')" || present=''
if [[ "$present" != 'yes' ]]; then
  log 'Adding Upgrade Status for this run.'
  cp composer.json "$work/composer.json" || fail 'There is no composer.json here. Set SENTINEL_PROJECT_DIR.'
  if [[ -f composer.lock ]]; then
    cp composer.lock "$work/composer.lock"
  fi
  if ! command -v composer > /dev/null 2>&1; then
    log 'Composer is not in the image.'
    report_problem install_failed || true
    exit 1
  fi
  if ! composer require --dev --no-interaction --no-progress drupal/upgrade_status > "$work/composer.log" 2>&1; then
    core="$("${drush[@]}" status --field=drupal-version 2> /dev/null | tr -d '[:space:]')"
    if [[ -z "$core" ]] || ! composer require --dev --no-interaction --no-progress drupal/upgrade_status "drupal/core-dev:$core" > "$work/composer.log" 2>&1; then
      tail -n 20 "$work/composer.log" >&2
      log "Composer could not add Upgrade Status without changing the site's locked versions."
      report_problem install_failed || true
      exit 1
    fi
  fi
fi
enabled_modules() {
  "${drush[@]}" pm:list --type=module --status=enabled --field=name 2> /dev/null | tr -d ' ' | sort
}
enabled_modules > "$work/modules_before"
if ! "${drush[@]}" pm:enable upgrade_status --yes > "$work/enable.log" 2>&1; then
  tail -n 20 "$work/enable.log" >&2
  log 'Upgrade Status could not be enabled.'
  report_problem install_failed || true
  exit 1
fi

# The modules this run turned on, to turn off again at the end.
enabled_modules | comm -13 "$work/modules_before" - > "$work/added_modules"

# 4. The scan. Exit code 3 means it found problems, which is a good scan.
log 'Scanning. This can take several minutes.'
"${drush[@]}" upgrade_status:analyze --all > "$work/analyze.log" 2>&1
code=$?
if [[ $code -ne 0 && $code -ne 3 ]]; then
  tail -n 20 "$work/analyze.log" >&2
  log "The scan failed (exit code $code)."
  report_problem scan_failed || true
  exit 1
fi

# 5. Send the stored result. The connector reports scan_failed itself for an
# incomplete scan, and exits 0 when the scan route is closed.
SENTINEL_SCAN_KEY="$key" \
SENTINEL_CONNECTOR_SITE_UUID="$uuid" \
SENTINEL_CONNECTOR_API_BASE_URL="$api" \
  "${drush[@]}" sentinel_connector:upgrade-status --scan-report --scan-started="$started"
