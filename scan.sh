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
  # Scheme, host and port only: no path, query, fragment or credentials.
  [[ "$1" =~ ^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$ || "$1" =~ ^http://(localhost|[a-z0-9.-]+\.localhost)(:[0-9]{1,5})?$ ]]
}
api_given="${SENTINEL_API_URL:-${SENTINEL_CONNECTOR_API_BASE_URL:-}}"
# Lower case, as the connector stores it, so the two can be compared.
api_given="$(printf '%s' "$api_given" | tr '[:upper:]' '[:lower:]')"
api="${api_given:-$DEFAULT_API_URL}"
api="${api%/}"
api_given="${api_given%/}"
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
    else
      # The site had no lock file: drop the one made for the scan.
      rm -f composer.lock
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

trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# Drush must find the site, or the job is set up wrong. This needs no
# database.
root="$("${drush[@]}" status --field=root 2> /dev/null | trim)" || root=''
[[ -n "$root" && -d "$root" ]] || fail "Drush cannot find the Drupal site from here. Set working-directory (SENTINEL_PROJECT_DIR) to your site's project folder in the image."

# Composer work happens in the site's own project root, found from Drupal's
# root, never in a checkout that only looks like one.
dir="$root"
while [[ "$dir" != / && ! -f "$dir/composer.json" ]]; do
  dir="$(dirname "$dir")"
done
if [[ -f "$dir/composer.json" ]]; then
  cd "$dir" || fail "Cannot open $dir."
fi

# 1. A working Drupal with its database.
bootstrap="$("${drush[@]}" status --field=bootstrap 2> /dev/null | trim)" || bootstrap=''
if [[ "$bootstrap" != 'Successful' ]]; then
  db="$("${drush[@]}" status --field=db-status 2> /dev/null | trim)" || db=''
  if [[ "$db" == 'Connected' ]]; then
    log 'Drupal reaches its database but does not start. Check the site image.'
    report_problem scan_failed || true
    exit 1
  fi
  log 'Drupal has no working database here, so there is nothing to scan.'
  # Passes only when Sentinel heard about it (or the route is closed).
  report_problem no_database || exit 1
  exit 0
fi

# Results and problems must go to the same Sentinel. Ask the connector where
# it sends: with a given URL it must agree (settings.php wins over the
# environment in the connector); without one, problems follow it. A connector
# URL that is not valid stops here, so nothing goes to production by mistake.
url_env=()
if [[ -n "$api_given" ]]; then
  url_env=(SENTINEL_CONNECTOR_API_BASE_URL="$api")
fi
# shellcheck disable=SC2016 # PHP code, expanded by PHP.
resolved="$(env ${url_env[@]+"${url_env[@]}"} "${drush[@]}" php:eval '
  $class = "Drupal\\sentinel_connector\\ApiBaseUrlResolver";
  if (\Drupal::moduleHandler()->moduleExists("sentinel_connector")) {
    if (class_exists($class)) {
      $url = \Drupal::service($class)->getUrl();
      echo $url ?? "INVALID";
    }
    else {
      // Connector 1.3 and older kept the URL in configuration.
      echo strtolower(rtrim((string) \Drupal::config("sentinel_connector.settings")->get("api_base_url"), "/"));
    }
  }' 2> /dev/null | trim)" || fail 'Could not ask the connector which Sentinel it sends to. Nothing was sent.'
resolved="${resolved%/}"
if [[ "$resolved" == INVALID ]] || { [[ -n "$resolved" ]] && ! valid_url "$resolved"; }; then
  fail "The connector's Sentinel API URL is not valid. Fix it in settings.php or set api-url (SENTINEL_API_URL). Nothing was sent."
fi
if [[ -n "$resolved" ]]; then
  if [[ -n "$api_given" && "$resolved" != "$api" ]]; then
    fail "The connector sends to $resolved (set in settings.php), not to $api. Remove api-url (SENTINEL_API_URL) or change the setting. Nothing was sent."
  fi
  api="$resolved"
fi

# 2. The connector, new enough to send a scan report.
connector="$("${drush[@]}" php:eval '
  if (\Drupal::moduleHandler()->moduleExists("sentinel_connector") && class_exists("Drupal\\sentinel_connector\\PayloadBuilder")) {
    echo \Drupal\sentinel_connector\PayloadBuilder::CONNECTOR_VERSION;
  }' 2> /dev/null | trim)" || connector=''
# shellcheck disable=SC2016 # PHP code, expanded by PHP.
if [[ -z "$connector" ]] || ! php -r 'exit(version_compare($argv[1], $argv[2], ">=") ? 0 : 1);' "$connector" "$MIN_CONNECTOR_VERSION"; then
  log "The Sentinel Connector module must be enabled at version $MIN_CONNECTOR_VERSION or later (found: ${connector:-none})."
  report_problem connector_outdated || true
  exit 1
fi

# Every package the site's lock file held is still at the same version.
locked_versions_kept() {
  [[ -f "$work/composer.lock" ]] || return 0
  # shellcheck disable=SC2016 # PHP code, expanded by PHP.
  php -r '
    $versions = function (string $file): array {
      $lock = json_decode((string) file_get_contents($file), TRUE) ?: [];
      $out = [];
      foreach (array_merge($lock["packages"] ?? [], $lock["packages-dev"] ?? []) as $package) {
        $out[$package["name"]] = ($package["version"] ?? "") . "@" . ($package["source"]["reference"] ?? $package["dist"]["reference"] ?? "");
      }
      return $out;
    };
    $before = $versions($argv[1]);
    $after = $versions($argv[2]);
    foreach ($before as $name => $version) {
      if (($after[$name] ?? NULL) !== $version) {
        fwrite(STDERR, "Adding Upgrade Status would change $name.\n");
        exit(1);
      }
    }' "$work/composer.lock" composer.lock
}

# 3. Upgrade Status, added for this run only, never changing locked versions.
present="$("${drush[@]}" php:eval 'echo \Drupal::service("extension.list.module")->exists("upgrade_status") ? "yes" : "no";' 2> /dev/null | trim)" || present=''
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
  if composer show --locked drupal/upgrade_status > /dev/null 2>&1; then
    # Already in the lock file, as a dev package left out of the image:
    # install exactly what the lock file holds.
    COMPOSER_NO_DEV=0 composer install --no-interaction --no-progress > "$work/composer.log" 2>&1
  else
    # Change the lock file only, check it, and only then install from it, so
    # a refused change never touches the installed packages.
    COMPOSER_NO_DEV=0 composer require --dev --no-install --no-interaction --no-progress drupal/upgrade_status > "$work/composer.log" 2>&1 || {
      core="$("${drush[@]}" status --field=drupal-version 2> /dev/null | trim)"
      [[ -n "$core" ]] && COMPOSER_NO_DEV=0 composer require --dev --no-install --no-interaction --no-progress drupal/upgrade_status "drupal/core-dev:$core" > "$work/composer.log" 2>&1
    } && locked_versions_kept && COMPOSER_NO_DEV=0 composer install --no-interaction --no-progress >> "$work/composer.log" 2>&1
  fi
  # shellcheck disable=SC2181 # The status of whichever branch ran.
  if [[ $? -ne 0 ]]; then
    tail -n 20 "$work/composer.log" >&2
    log "Composer could not add Upgrade Status without changing the site's locked versions."
    report_problem install_failed || true
    exit 1
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
# Without a given URL the connector uses its own setting.
report_env=(SENTINEL_SCAN_KEY="$key" SENTINEL_CONNECTOR_SITE_UUID="$uuid")
if [[ -n "$api_given" ]]; then
  report_env+=(SENTINEL_CONNECTOR_API_BASE_URL="$api")
fi
env "${report_env[@]}" "${drush[@]}" sentinel_connector:upgrade-status --scan-report --scan-started="$started"
