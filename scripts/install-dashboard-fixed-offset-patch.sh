#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Sandeep-Singh Gary Bajaj
# SPDX-License-Identifier: AGPL-3.0-or-later
# AI-NOTICE:Schema-Version=0.1
# AI-NOTICE:License=AGPL-3.0-or-later
# AI-NOTICE:Project=calendar
# AI-NOTICE:Repository=https://github.com/pi0n00r/calendar
# AI-NOTICE:Author=Sandeep-Singh Gary Bajaj
# AI-NOTICE:Scope=file

set -Eeuo pipefail
umask 022

EXPECTED_VERSION="6.5.2"
INSTALL_CONFIRMATION="INSTALL CALENDAR PATCH 6.5.2"
ROLLBACK_CONFIRMATION="ROLLBACK CALENDAR PATCH 6.5.2"
OFFICIAL_WIDGET_SHA256="5f6a67cd3c3bb86eb5f80e36c3baad2f85a877e9300e24a7d08c968529cdf460"
PATCHED_WIDGET_SHA256="9abec8e540d36a5c83d23f2a1c448dd899637328f50af1e0f3a26fddd2077e56"
TIMEZONE_SHA256="dddf840ec90da392ddce5f577d736f8cb94f85246936f879218749535356bd09"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WIDGET_SOURCE="$REPO_ROOT/lib/Dashboard/CalendarWidget.php"
TIMEZONE_SOURCE="${TIMEZONE_SOURCE:-$REPO_ROOT/resources/php/timezone-override.ini.example}"

CALENDAR_APP_DIR="${CALENDAR_APP_DIR:-}"
TIMEZONE_TARGET="${TIMEZONE_TARGET:-}"
SESSION_SOURCE="${SESSION_SOURCE:-}"
SESSION_TARGET="${SESSION_TARGET:-}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/nextcloud-calendar-fixed-offset}"
NEW_TIMEZONE_MODE="${NEW_TIMEZONE_MODE:-0644}"
NEW_SESSION_MODE="${NEW_SESSION_MODE:-0600}"
READINESS_URL="${READINESS_URL:-}"
READINESS_ATTEMPTS="${READINESS_ATTEMPTS:-30}"
READINESS_DELAY="${READINESS_DELAY:-2}"
EXECUTE=0
ROLLBACK=0
CONFIRM=""

PHP_VALIDATOR=()
VALIDATION_HOOK=()
RESTART_HOOK=()
WORK_DIR=""
TX_DIR=""
TRANSACTION_ACTIVE=0
TRANSACTION_RESTORED=0
RENDERED_TIMEZONE=""

usage() {
	cat <<'EOF'
Install the Nextcloud Calendar 6.5.2 Dashboard fixed-offset patch and its PHP
timezone/session overrides as one guarded transaction.

Usage:
  install-dashboard-fixed-offset-patch.sh [options]

Default behavior is a read-only plan. Mutation requires an action and its
action-specific exact confirmation phrase.

Required:
  --calendar-app-dir PATH    Installed Calendar app directory
  --timezone-target PATH     PHP timezone override destination
  --session-target PATH      Protected PHP Redis session override destination
  --session-source PATH      Protected Redis session override source (install only)

Transaction:
  --execute                  Install all three components
  --rollback                 Restore the latest verified backup transaction
  --confirm PHRASE           Exact action confirmation:
                             INSTALL CALENDAR PATCH 6.5.2
                             ROLLBACK CALENDAR PATCH 6.5.2
  --backup-root PATH         Backup root (default:
                             /var/backups/nextcloud-calendar-fixed-offset)
  --timezone-source PATH     Repo-owned SPDX-bearing timezone template
  --new-timezone-mode MODE   Mode for an absent timezone target (default: 0644)
  --new-session-mode MODE    Mode for an absent session target (default: 0600)

Validation and lifecycle:
  --php-validator PROGRAM    PHP syntax validator executable
  --php-validator-arg ARG    Append one validator argv item; repeat as needed
  --validation-hook PROGRAM  Optional validation hook executable
  --validation-arg ARG       Append one validation-hook argv item
  --restart-hook PROGRAM     Optional restart/OPcache-clear hook executable
  --restart-arg ARG          Append one restart-hook argv item
  --readiness-url URL        Optional HTTP(S) readiness endpoint
  --readiness-attempts N     Attempts after restart (default: 30)
  --readiness-delay SECONDS  Delay between attempts (default: 2)
  -h, --help                 Show this help

Hooks are executed directly as argv arrays; shell command strings are never
evaluated. The validation hook receives PHASE, WIDGET, TIMEZONE, SESSION.
EOF
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

is_uint() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

validate_mode() {
	[[ "$1" =~ ^0?[0-7]{3}$ ]] || die "invalid mode: $1"
}

normalize_mode() {
	printf '%03o\n' "$((8#${1#0}))"
}

require_regular_file() {
	local path="$1"
	local label="$2"
	[[ -f "$path" && ! -L "$path" ]] || die "$label is not a regular file"
}

require_target_shape() {
	local path="$1"
	local label="$2"
	[[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] \
		|| die "$label contains unsupported control whitespace"
	if [[ -e "$path" || -L "$path" ]]; then
		[[ -f "$path" && ! -L "$path" ]] || die "$label must be a regular file"
	else
		[[ -d "$(dirname -- "$path")" ]] || die "$label parent directory is absent"
	fi
}

sha256_file() {
	sha256sum -- "$1" | awk '{print $1}'
}

path_sha256() {
	printf '%s' "$1" | sha256sum | awk '{print $1}'
}

calendar_version() {
	local info="$CALENDAR_APP_DIR/appinfo/info.xml"
	local version
	local count
	require_regular_file "$info" "Calendar app metadata"
	count="$(grep -Ec '<version>[^<]+</version>' "$info")"
	[[ "$count" = "1" ]] || die "Calendar metadata has an ambiguous version"
	version="$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "$info")"
	printf '%s\n' "$version"
}

ini_value() {
	local key="$1"
	local file="$2"
	awk -v wanted="$key" '
		/^[[:space:]]*[;#]/ { next }
		{
			position = index($0, "=")
			if (position == 0) {
				next
			}
			name = substr($0, 1, position - 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
			if (name != wanted) {
				next
			}
			count++
			value = substr($0, position + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			result = value
		}
		END {
			if (count != 1) {
				exit 2
			}
			print result
		}
	' "$file"
}

compact_ini_value() {
	printf '%s' "$1" | tr -d '[:space:]"'
}

expect_ini_value() {
	local file="$1"
	local key="$2"
	local expected="$3"
	local value
	value="$(ini_value "$key" "$file")" || die "session override has missing or duplicate required settings"
	[[ "$(compact_ini_value "$value")" = "$expected" ]] \
		|| die "session override has an invalid required setting"
}

validate_session_source() {
	local file="$1"
	local require_protected_mode="$2"
	local mode
	local save_path

	require_regular_file "$file" "session override"
	[[ ! -s "$file" || "$(wc -c <"$file")" -le 65536 ]] \
		|| die "session override exceeds the size limit"
	if od -An -v -tx1 -- "$file" \
		| grep -Eq '(^|[[:space:]])00([[:space:]]|$)'; then
		die "session override contains a NUL byte"
	fi

	if [[ "$require_protected_mode" = "1" ]]; then
		mode="$(stat -c '%a' "$file")"
		[[ "$mode" = "600" ]] \
			|| die "protected session source must have mode 0600"
	fi

	expect_ini_value "$file" "session.save_handler" "redis"
	expect_ini_value "$file" "session.gc_maxlifetime" "604800"
	expect_ini_value "$file" "session.cookie_lifetime" "604800"
	expect_ini_value "$file" "redis.session.locking_enabled" "1"
	expect_ini_value "$file" "redis.session.lock_retries" "-1"
	expect_ini_value "$file" "redis.session.lock_wait_time" "10000"
	expect_ini_value "$file" "redis.session.early_refresh" "1"

	save_path="$(ini_value "session.save_path" "$file")" \
		|| die "session override has missing or duplicate Redis URL"
	if printf '%s' "$save_path" | grep -Eqi 'replace|change[_-]?me|placeholder|example|<[^>]+>'; then
		die "session override still contains a credential placeholder"
	fi
	if ! printf '%s' "$save_path" \
		| grep -Eq '([?&]auth=[^&"[:space:]]+)|(redis(s)?://[^/@:]+:[^@/]+@)'; then
		die "session override Redis URL lacks a non-empty auth value"
	fi
}

render_timezone_override() {
	local output="$1"
	local value
	require_regular_file "$TIMEZONE_SOURCE" "timezone override template"
	grep -q 'SPDX-License-Identifier: AGPL-3.0-or-later' "$TIMEZONE_SOURCE" \
		|| die "timezone override template lacks its SPDX license header"
	value="$(ini_value "date.timezone" "$TIMEZONE_SOURCE")" \
		|| die "timezone template has missing or duplicate date.timezone"
	[[ "$(compact_ini_value "$value")" = "America/Toronto" ]] \
		|| die "timezone template does not select America/Toronto"
	printf 'date.timezone = "America/Toronto"\n' >"$output"
	chmod 0600 "$output"
	[[ "$(sha256_file "$output")" = "$TIMEZONE_SHA256" ]] \
		|| die "rendered timezone override does not match the reviewed payload"
}

run_php_lint() {
	local file="$1"
	(("${#PHP_VALIDATOR[@]}" > 0)) \
		|| die "no PHP validator is available; use --php-validator"
	"${PHP_VALIDATOR[@]}" -l "$file" >/dev/null \
		|| die "PHP syntax validation failed"
}

run_validation_hook() {
	local phase="$1"
	local widget="$2"
	local timezone="$3"
	local session="$4"
	if (("${#VALIDATION_HOOK[@]}" > 0)); then
		"${VALIDATION_HOOK[@]}" "$phase" "$widget" "$timezone" "$session"
	fi
}

run_restart_hook() {
	if (("${#RESTART_HOOK[@]}" > 0)); then
		"${RESTART_HOOK[@]}"
	fi
}

wait_ready() {
	local attempt
	[[ -z "$READINESS_URL" ]] && return 0
	[[ "$READINESS_URL" =~ ^https?:// ]] || die "readiness URL must use HTTP or HTTPS"
	command -v curl >/dev/null 2>&1 || die "curl is required for readiness checks"
	for ((attempt = 1; attempt <= READINESS_ATTEMPTS; attempt++)); do
		if curl --fail --silent --show-error --max-time 10 -- "$READINESS_URL" >/dev/null; then
			return 0
		fi
		sleep "$READINESS_DELAY"
	done
	return 1
}

target_attributes() {
	local target="$1"
	local default_mode="$2"
	if [[ -e "$target" ]]; then
		printf '%s:%s:%s\n' \
			"$(stat -c '%u' "$target")" \
			"$(stat -c '%g' "$target")" \
			"$(normalize_mode "$(stat -c '%a' "$target")")"
	else
		printf '%s:%s:%s\n' \
			"${EUID:-$(id -u)}" \
			"$(id -g)" \
			"$(normalize_mode "$default_mode")"
	fi
}

prepare_candidate() {
	local source="$1"
	local target="$2"
	local attributes="$3"
	local output_variable="$4"
	local uid gid mode
	local candidate

	IFS=: read -r uid gid mode <<<"$attributes"
	candidate="$(mktemp "$(dirname -- "$target")/.calendar-patch.$(basename -- "$target").XXXXXX")"
	chmod 0600 "$candidate"
	if [[ -e "$target" ]]; then
		cp --attributes-only --preserve=all -- "$target" "$candidate"
		cat -- "$source" >"$candidate"
	else
		install -m "$mode" -- "$source" "$candidate"
		chown "$uid:$gid" "$candidate"
		chmod "$mode" "$candidate"
	fi
	[[ "$(stat -c '%u:%g:%a' "$candidate")" = "$uid:$gid:${mode#0}" ]] \
		|| die "candidate attributes do not match the required target attributes"
	printf -v "$output_variable" '%s' "$candidate"
}

write_metadata() {
	local directory="$1"
	local timezone_before_state="$2"
	local timezone_before_sha="$3"
	local session_before_state="$4"
	local session_before_sha="$5"
	local session_after_sha="$6"
	local calendar_attributes="$7"
	local timezone_attributes="$8"
	local session_attributes="$9"
	local calendar_uid calendar_gid calendar_mode
	local timezone_uid timezone_gid timezone_mode
	local session_uid session_gid session_mode

	IFS=: read -r calendar_uid calendar_gid calendar_mode <<<"$calendar_attributes"
	IFS=: read -r timezone_uid timezone_gid timezone_mode <<<"$timezone_attributes"
	IFS=: read -r session_uid session_gid session_mode <<<"$session_attributes"

	install -m 0600 /dev/null "$directory/metadata.tmp"
	cat >"$directory/metadata.tmp" <<EOF
format_version=1
calendar_version=$EXPECTED_VERSION
calendar_target_path_sha256=$(path_sha256 "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php")
timezone_target_path_sha256=$(path_sha256 "$TIMEZONE_TARGET")
session_target_path_sha256=$(path_sha256 "$SESSION_TARGET")
calendar_before_sha256=$OFFICIAL_WIDGET_SHA256
calendar_after_sha256=$PATCHED_WIDGET_SHA256
timezone_before_state=$timezone_before_state
timezone_before_sha256=$timezone_before_sha
timezone_after_sha256=$TIMEZONE_SHA256
session_before_state=$session_before_state
session_before_sha256=$session_before_sha
session_after_sha256=$session_after_sha
calendar_after_uid=$calendar_uid
calendar_after_gid=$calendar_gid
calendar_after_mode=$calendar_mode
timezone_after_uid=$timezone_uid
timezone_after_gid=$timezone_gid
timezone_after_mode=$timezone_mode
session_after_uid=$session_uid
session_after_gid=$session_gid
session_after_mode=$session_mode
EOF
	chmod 0600 "$directory/metadata.tmp"
	mv -- "$directory/metadata.tmp" "$directory/metadata"
	(
		cd -- "$directory"
		install -m 0600 /dev/null metadata.sha256.tmp
		sha256sum metadata >metadata.sha256.tmp
		chmod 0600 metadata.sha256.tmp
		mv -- metadata.sha256.tmp metadata.sha256
	)
}

meta_get() {
	local directory="$1"
	local key="$2"
	local metadata="$directory/metadata"
	local count
	count="$(grep -c "^${key}=" "$metadata")"
	[[ "$count" = "1" ]] || return 1
	sed -n "s/^${key}=//p" "$metadata"
}

require_meta_match() {
	local directory="$1"
	local key="$2"
	local pattern="$3"
	local value
	value="$(meta_get "$directory" "$key")" || die "backup metadata is incomplete"
	[[ "$value" =~ $pattern ]] || die "backup metadata has an invalid value"
}

validate_backup_metadata() {
	local directory="$1"
	local state
	[[ -d "$directory" && ! -L "$directory" ]] || die "backup transaction is invalid"
	require_regular_file "$directory/metadata" "backup metadata"
	require_regular_file "$directory/metadata.sha256" "backup metadata checksum"
	(
		cd -- "$directory"
		sha256sum -c metadata.sha256 >/dev/null
	) || die "backup metadata checksum failed"

	[[ "$(meta_get "$directory" format_version)" = "1" ]] || die "unsupported backup format"
	[[ "$(meta_get "$directory" calendar_version)" = "$EXPECTED_VERSION" ]] \
		|| die "backup Calendar version does not match"
	[[ "$(meta_get "$directory" calendar_before_sha256)" = "$OFFICIAL_WIDGET_SHA256" ]] \
		|| die "backup does not restore the official Calendar widget"
	[[ "$(meta_get "$directory" calendar_after_sha256)" = "$PATCHED_WIDGET_SHA256" ]] \
		|| die "backup patched widget hash does not match"
	[[ "$(meta_get "$directory" timezone_after_sha256)" = "$TIMEZONE_SHA256" ]] \
		|| die "backup timezone hash does not match"

	require_meta_match "$directory" calendar_target_path_sha256 '^[0-9a-f]{64}$'
	require_meta_match "$directory" timezone_target_path_sha256 '^[0-9a-f]{64}$'
	require_meta_match "$directory" session_target_path_sha256 '^[0-9a-f]{64}$'
	require_meta_match "$directory" session_after_sha256 '^[0-9a-f]{64}$'
	require_meta_match "$directory" calendar_after_uid '^[0-9]+$'
	require_meta_match "$directory" calendar_after_gid '^[0-9]+$'
	require_meta_match "$directory" calendar_after_mode '^[0-7]{3,4}$'
	require_meta_match "$directory" timezone_after_uid '^[0-9]+$'
	require_meta_match "$directory" timezone_after_gid '^[0-9]+$'
	require_meta_match "$directory" timezone_after_mode '^[0-7]{3,4}$'
	require_meta_match "$directory" session_after_uid '^[0-9]+$'
	require_meta_match "$directory" session_after_gid '^[0-9]+$'
	require_meta_match "$directory" session_after_mode '^[0-7]{3,4}$'

	for state_key in timezone_before_state session_before_state; do
		state="$(meta_get "$directory" "$state_key")"
		[[ "$state" = "present" || "$state" = "absent" ]] \
			|| die "backup metadata has an invalid prior-state marker"
	done
}

verify_backup_payloads() {
	local directory="$1"
	local state
	local expected

	require_regular_file "$directory/CalendarWidget.php" "Calendar widget backup"
	[[ "$(sha256_file "$directory/CalendarWidget.php")" = "$OFFICIAL_WIDGET_SHA256" ]] \
		|| die "Calendar widget backup hash is invalid"

	state="$(meta_get "$directory" timezone_before_state)"
	expected="$(meta_get "$directory" timezone_before_sha256)"
	if [[ "$state" = "present" ]]; then
		require_regular_file "$directory/timezone-override.ini" "timezone backup"
		[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "timezone backup metadata is invalid"
		[[ "$(sha256_file "$directory/timezone-override.ini")" = "$expected" ]] \
			|| die "timezone backup hash is invalid"
	else
		[[ "$expected" = "-" && ! -e "$directory/timezone-override.ini" ]] \
			|| die "timezone absence backup is inconsistent"
	fi

	state="$(meta_get "$directory" session_before_state)"
	expected="$(meta_get "$directory" session_before_sha256)"
	if [[ "$state" = "present" ]]; then
		require_regular_file "$directory/session-override.ini" "session backup"
		[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "session backup metadata is invalid"
		[[ "$(sha256_file "$directory/session-override.ini")" = "$expected" ]] \
			|| die "session backup hash is invalid"
	else
		[[ "$expected" = "-" && ! -e "$directory/session-override.ini" ]] \
			|| die "session absence backup is inconsistent"
	fi
}

atomic_restore_file() {
	local backup="$1"
	local target="$2"
	local uid="$3"
	local gid="$4"
	local mode="$5"
	local temporary
	temporary="$(mktemp "$(dirname -- "$target")/.calendar-restore.$(basename -- "$target").XXXXXX")"
	chmod 0600 "$temporary"
	if [[ -e "$target" ]]; then
		cp --attributes-only --preserve=all -- "$target" "$temporary"
	fi
	cat -- "$backup" >"$temporary"
	chown "$uid:$gid" "$temporary"
	chmod "$mode" "$temporary"
	mv -f -- "$temporary" "$target"
}

restore_backup() {
	local directory="$1"
	local timezone_state
	local session_state
	local calendar_uid calendar_gid calendar_mode
	local timezone_uid timezone_gid timezone_mode
	local session_uid session_gid session_mode

	validate_backup_metadata "$directory"
	verify_backup_payloads "$directory"

	session_state="$(meta_get "$directory" session_before_state)"
	timezone_state="$(meta_get "$directory" timezone_before_state)"
	calendar_uid="$(meta_get "$directory" calendar_after_uid)"
	calendar_gid="$(meta_get "$directory" calendar_after_gid)"
	calendar_mode="$(meta_get "$directory" calendar_after_mode)"
	timezone_uid="$(meta_get "$directory" timezone_after_uid)"
	timezone_gid="$(meta_get "$directory" timezone_after_gid)"
	timezone_mode="$(meta_get "$directory" timezone_after_mode)"
	session_uid="$(meta_get "$directory" session_after_uid)"
	session_gid="$(meta_get "$directory" session_after_gid)"
	session_mode="$(meta_get "$directory" session_after_mode)"

	if [[ "$session_state" = "present" ]]; then
		atomic_restore_file "$directory/session-override.ini" "$SESSION_TARGET" \
			"$session_uid" "$session_gid" "$session_mode"
	else
		rm -f -- "$SESSION_TARGET"
	fi
	if [[ "$timezone_state" = "present" ]]; then
		atomic_restore_file "$directory/timezone-override.ini" "$TIMEZONE_TARGET" \
			"$timezone_uid" "$timezone_gid" "$timezone_mode"
	else
		rm -f -- "$TIMEZONE_TARGET"
	fi
	atomic_restore_file "$directory/CalendarWidget.php" \
		"$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php" \
		"$calendar_uid" "$calendar_gid" "$calendar_mode"

	[[ "$(sha256_file "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php")" = "$OFFICIAL_WIDGET_SHA256" ]] \
		|| die "restored Calendar widget is not the official baseline"
	if [[ "$timezone_state" = "present" ]]; then
		[[ "$(sha256_file "$TIMEZONE_TARGET")" = "$(meta_get "$directory" timezone_before_sha256)" ]] \
			|| die "restored timezone override verification failed"
	else
		[[ ! -e "$TIMEZONE_TARGET" ]] || die "timezone override removal failed"
	fi
	if [[ "$session_state" = "present" ]]; then
		[[ "$(sha256_file "$SESSION_TARGET")" = "$(meta_get "$directory" session_before_sha256)" ]] \
			|| die "restored session override verification failed"
	else
		[[ ! -e "$SESSION_TARGET" ]] || die "session override removal failed"
	fi
}

on_exit() {
	local rc=$?
	local lifecycle_ok
	trap - EXIT ERR
	if ((rc != 0 && TRANSACTION_ACTIVE == 1 && TRANSACTION_RESTORED == 0)); then
		printf 'Install failed after replacement; restoring all three components.\n' >&2
		set +e
		if (restore_backup "$TX_DIR"); then
			TRANSACTION_RESTORED=1
			lifecycle_ok=1
			if ! run_restart_hook >/dev/null 2>&1; then
				lifecycle_ok=0
			elif ! (wait_ready) >/dev/null 2>&1; then
				lifecycle_ok=0
			fi
			if ((lifecycle_ok == 1)); then
				printf 'Automatic rollback restored all files and verified lifecycle recovery.\n' >&2
			else
				printf 'ERROR: automatic rollback restored all files, but lifecycle recovery failed; inspect protected backup: %s\n' "$TX_DIR" >&2
				rc=2
			fi
		else
			printf 'ERROR: automatic rollback failed; inspect protected backup: %s\n' "$TX_DIR" >&2
			rc=2
		fi
		set -e
	fi
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf -- "$WORK_DIR"
	fi
	exit "$rc"
}
trap on_exit EXIT

latest_backup_dir() {
	local link="$BACKUP_ROOT/latest"
	local name
	[[ -L "$link" ]] || die "no latest backup transaction exists"
	name="$(readlink -- "$link")"
	[[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "latest backup link is unsafe"
	printf '%s/%s\n' "$BACKUP_ROOT" "$name"
}

verify_installed_attributes() {
	local target="$1"
	local directory="$2"
	local prefix="$3"
	[[ "$(stat -c '%u' "$target")" = "$(meta_get "$directory" "${prefix}_after_uid")" ]] \
		|| die "$prefix target owner changed"
	[[ "$(stat -c '%g' "$target")" = "$(meta_get "$directory" "${prefix}_after_gid")" ]] \
		|| die "$prefix target group changed"
	[[ "$(normalize_mode "$(stat -c '%a' "$target")")" = \
		"$(normalize_mode "$(meta_get "$directory" "${prefix}_after_mode")")" ]] \
		|| die "$prefix target mode changed"
}

perform_rollback() {
	local directory
	local session_after_sha

	directory="$(latest_backup_dir)"
	validate_backup_metadata "$directory"
	verify_backup_payloads "$directory"
	[[ "$(path_sha256 "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php")" = \
		"$(meta_get "$directory" calendar_target_path_sha256)" ]] \
		|| die "Calendar target does not match this backup"
	[[ "$(path_sha256 "$TIMEZONE_TARGET")" = \
		"$(meta_get "$directory" timezone_target_path_sha256)" ]] \
		|| die "timezone target does not match this backup"
	[[ "$(path_sha256 "$SESSION_TARGET")" = \
		"$(meta_get "$directory" session_target_path_sha256)" ]] \
		|| die "session target does not match this backup"

	session_after_sha="$(meta_get "$directory" session_after_sha256)"
	[[ -f "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php" \
		&& "$(sha256_file "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php")" = "$PATCHED_WIDGET_SHA256" ]] \
		|| die "Calendar target is not the installed patch"
	[[ -f "$TIMEZONE_TARGET" && "$(sha256_file "$TIMEZONE_TARGET")" = "$TIMEZONE_SHA256" ]] \
		|| die "timezone target is not the installed patch"
	[[ -f "$SESSION_TARGET" && "$(sha256_file "$SESSION_TARGET")" = "$session_after_sha" ]] \
		|| die "session target is not the installed transaction"
	verify_installed_attributes "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php" "$directory" calendar
	verify_installed_attributes "$TIMEZONE_TARGET" "$directory" timezone
	verify_installed_attributes "$SESSION_TARGET" "$directory" session

	run_php_lint "$directory/CalendarWidget.php"
	restore_backup "$directory"
	run_php_lint "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php"
	run_restart_hook
	wait_ready || die "readiness check failed after rollback"
	printf 'Rollback restored Calendar 6.5.2 and both prior INI states.\n'
	printf 'No CalDAV object or database content was accessed or changed.\n'
}

while (($# > 0)); do
	case "$1" in
		--calendar-app-dir)
			[[ $# -ge 2 ]] || die "missing value for $1"
			CALENDAR_APP_DIR="$2"
			shift 2
			;;
		--timezone-source)
			[[ $# -ge 2 ]] || die "missing value for $1"
			TIMEZONE_SOURCE="$2"
			shift 2
			;;
		--timezone-target)
			[[ $# -ge 2 ]] || die "missing value for $1"
			TIMEZONE_TARGET="$2"
			shift 2
			;;
		--session-source)
			[[ $# -ge 2 ]] || die "missing value for $1"
			SESSION_SOURCE="$2"
			shift 2
			;;
		--session-target)
			[[ $# -ge 2 ]] || die "missing value for $1"
			SESSION_TARGET="$2"
			shift 2
			;;
		--backup-root)
			[[ $# -ge 2 ]] || die "missing value for $1"
			BACKUP_ROOT="$2"
			shift 2
			;;
		--new-timezone-mode)
			[[ $# -ge 2 ]] || die "missing value for $1"
			NEW_TIMEZONE_MODE="$2"
			shift 2
			;;
		--new-session-mode)
			[[ $# -ge 2 ]] || die "missing value for $1"
			NEW_SESSION_MODE="$2"
			shift 2
			;;
		--php-validator)
			[[ $# -ge 2 ]] || die "missing value for $1"
			PHP_VALIDATOR=("$2")
			shift 2
			;;
		--php-validator-arg)
			[[ $# -ge 2 ]] || die "missing value for $1"
			PHP_VALIDATOR+=("$2")
			shift 2
			;;
		--validation-hook)
			[[ $# -ge 2 ]] || die "missing value for $1"
			VALIDATION_HOOK=("$2")
			shift 2
			;;
		--validation-arg)
			[[ $# -ge 2 ]] || die "missing value for $1"
			VALIDATION_HOOK+=("$2")
			shift 2
			;;
		--restart-hook)
			[[ $# -ge 2 ]] || die "missing value for $1"
			RESTART_HOOK=("$2")
			shift 2
			;;
		--restart-arg)
			[[ $# -ge 2 ]] || die "missing value for $1"
			RESTART_HOOK+=("$2")
			shift 2
			;;
		--readiness-url)
			[[ $# -ge 2 ]] || die "missing value for $1"
			READINESS_URL="$2"
			shift 2
			;;
		--readiness-attempts)
			[[ $# -ge 2 ]] || die "missing value for $1"
			READINESS_ATTEMPTS="$2"
			shift 2
			;;
		--readiness-delay)
			[[ $# -ge 2 ]] || die "missing value for $1"
			READINESS_DELAY="$2"
			shift 2
			;;
		--execute)
			EXECUTE=1
			shift
			;;
		--rollback)
			ROLLBACK=1
			shift
			;;
		--confirm)
			[[ $# -ge 2 ]] || die "missing value for $1"
			CONFIRM="$2"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

((EXECUTE + ROLLBACK <= 1)) || die "--execute and --rollback are mutually exclusive"
if ((EXECUTE == 1)); then
	[[ "$CONFIRM" = "$INSTALL_CONFIRMATION" ]] \
		|| die "--execute requires --confirm '$INSTALL_CONFIRMATION'"
elif ((ROLLBACK == 1)); then
	[[ "$CONFIRM" = "$ROLLBACK_CONFIRMATION" ]] \
		|| die "--rollback requires --confirm '$ROLLBACK_CONFIRMATION'"
elif [[ -n "$CONFIRM" ]]; then
	die "--confirm is only valid with --execute or --rollback"
fi
[[ -n "$CALENDAR_APP_DIR" ]] || die "--calendar-app-dir is required"
[[ -n "$TIMEZONE_TARGET" ]] || die "--timezone-target is required"
[[ -n "$SESSION_TARGET" ]] || die "--session-target is required"
[[ -d "$CALENDAR_APP_DIR" ]] || die "Calendar app directory is absent"
require_target_shape "$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php" "Calendar widget target"
require_target_shape "$TIMEZONE_TARGET" "timezone target"
require_target_shape "$SESSION_TARGET" "session target"
validate_mode "$NEW_TIMEZONE_MODE"
validate_mode "$NEW_SESSION_MODE"
if ! is_uint "$READINESS_ATTEMPTS" || ((READINESS_ATTEMPTS == 0)); then
	die "readiness attempts must be a positive integer"
fi
is_uint "$READINESS_DELAY" || die "readiness delay must be a non-negative integer"
[[ "$(calendar_version)" = "$EXPECTED_VERSION" ]] \
	|| die "installed Calendar version is not exactly $EXPECTED_VERSION"

if (("${#PHP_VALIDATOR[@]}" == 0)) && command -v php >/dev/null 2>&1; then
	PHP_VALIDATOR=(php)
fi

if ((ROLLBACK == 1)); then
	perform_rollback
	exit 0
fi

require_regular_file "$WIDGET_SOURCE" "patched widget source"
[[ "$(sha256_file "$WIDGET_SOURCE")" = "$PATCHED_WIDGET_SHA256" ]] \
	|| die "patched widget source hash does not match the reviewed patch"
[[ -n "$SESSION_SOURCE" ]] || die "--session-source is required for plan/install"
validate_session_source "$SESSION_SOURCE" 1

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/calendar-fixed-offset.XXXXXX")"
chmod 0700 "$WORK_DIR"
RENDERED_TIMEZONE="$WORK_DIR/timezone-override.ini"
render_timezone_override "$RENDERED_TIMEZONE"

LIVE_WIDGET="$CALENDAR_APP_DIR/lib/Dashboard/CalendarWidget.php"
LIVE_WIDGET_SHA="$(sha256_file "$LIVE_WIDGET")"
SESSION_SOURCE_SHA="$(sha256_file "$SESSION_SOURCE")"

if [[ "$LIVE_WIDGET_SHA" = "$PATCHED_WIDGET_SHA256" ]]; then
	[[ -f "$TIMEZONE_TARGET" && "$(sha256_file "$TIMEZONE_TARGET")" = "$TIMEZONE_SHA256" ]] \
		|| die "widget is patched but timezone override does not match"
	[[ -f "$SESSION_TARGET" && "$(sha256_file "$SESSION_TARGET")" = "$SESSION_SOURCE_SHA" ]] \
		|| die "widget is patched but session override does not match"
	validate_session_source "$SESSION_TARGET" 0
	printf 'All three components are already installed; no changes required.\n'
	exit 0
fi

[[ "$LIVE_WIDGET_SHA" = "$OFFICIAL_WIDGET_SHA256" ]] \
	|| die "Calendar widget hash is neither the official baseline nor this patch"

run_php_lint "$WIDGET_SOURCE"
run_validation_hook candidate "$WIDGET_SOURCE" "$RENDERED_TIMEZONE" "$SESSION_SOURCE"

if ((EXECUTE == 0)); then
	printf 'PLAN: Calendar %s official widget is eligible for the fixed-offset patch.\n' "$EXPECTED_VERSION"
	printf 'PLAN: install the reviewed Toronto timezone override.\n'
	printf 'PLAN: install the structurally validated protected Redis session override.\n'
	printf 'PLAN: preserve every existing target owner/group/mode; absent INIs use modes %s and %s.\n' \
		"$(normalize_mode "$NEW_TIMEZONE_MODE")" "$(normalize_mode "$NEW_SESSION_MODE")"
	printf 'PLAN: write verified rollback material under %s.\n' "$BACKUP_ROOT"
	printf 'No files were changed. No CalDAV object or database content was accessed.\n'
	exit 0
fi

CALENDAR_ATTRIBUTES="$(target_attributes "$LIVE_WIDGET" 0644)"
TIMEZONE_ATTRIBUTES="$(target_attributes "$TIMEZONE_TARGET" "$NEW_TIMEZONE_MODE")"
SESSION_ATTRIBUTES="$(target_attributes "$SESSION_TARGET" "$NEW_SESSION_MODE")"

TIMEZONE_BEFORE_STATE=absent
TIMEZONE_BEFORE_SHA=-
SESSION_BEFORE_STATE=absent
SESSION_BEFORE_SHA=-
if [[ -e "$TIMEZONE_TARGET" ]]; then
	TIMEZONE_BEFORE_STATE=present
	TIMEZONE_BEFORE_SHA="$(sha256_file "$TIMEZONE_TARGET")"
fi
if [[ -e "$SESSION_TARGET" ]]; then
	SESSION_BEFORE_STATE=present
	SESSION_BEFORE_SHA="$(sha256_file "$SESSION_TARGET")"
fi

install -d -m 0700 -- "$BACKUP_ROOT"
TX_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%06x' "$((RANDOM * RANDOM % 16777216))")"
TX_DIR="$BACKUP_ROOT/$TX_ID"
[[ ! -e "$TX_DIR" ]] || die "backup transaction already exists"
mkdir -m 0700 -- "$TX_DIR"

cp --preserve=all -- "$LIVE_WIDGET" "$TX_DIR/CalendarWidget.php"
chown "${EUID:-$(id -u)}:$(id -g)" "$TX_DIR/CalendarWidget.php"
chmod 0600 "$TX_DIR/CalendarWidget.php"
if [[ "$TIMEZONE_BEFORE_STATE" = "present" ]]; then
	cp --preserve=all -- "$TIMEZONE_TARGET" "$TX_DIR/timezone-override.ini"
	chown "${EUID:-$(id -u)}:$(id -g)" "$TX_DIR/timezone-override.ini"
	chmod 0600 "$TX_DIR/timezone-override.ini"
fi
if [[ "$SESSION_BEFORE_STATE" = "present" ]]; then
	cp --preserve=all -- "$SESSION_TARGET" "$TX_DIR/session-override.ini"
	chown "${EUID:-$(id -u)}:$(id -g)" "$TX_DIR/session-override.ini"
	chmod 0600 "$TX_DIR/session-override.ini"
fi
write_metadata "$TX_DIR" \
	"$TIMEZONE_BEFORE_STATE" "$TIMEZONE_BEFORE_SHA" \
	"$SESSION_BEFORE_STATE" "$SESSION_BEFORE_SHA" \
	"$SESSION_SOURCE_SHA" \
	"$CALENDAR_ATTRIBUTES" "$TIMEZONE_ATTRIBUTES" "$SESSION_ATTRIBUTES"
validate_backup_metadata "$TX_DIR"
verify_backup_payloads "$TX_DIR"

WIDGET_CANDIDATE=""
TIMEZONE_CANDIDATE=""
SESSION_CANDIDATE=""
prepare_candidate "$WIDGET_SOURCE" "$LIVE_WIDGET" "$CALENDAR_ATTRIBUTES" WIDGET_CANDIDATE
prepare_candidate "$RENDERED_TIMEZONE" "$TIMEZONE_TARGET" "$TIMEZONE_ATTRIBUTES" TIMEZONE_CANDIDATE
prepare_candidate "$SESSION_SOURCE" "$SESSION_TARGET" "$SESSION_ATTRIBUTES" SESSION_CANDIDATE
run_php_lint "$WIDGET_CANDIDATE"
validate_session_source "$SESSION_CANDIDATE" 0

TRANSACTION_ACTIVE=1
mv -f -- "$WIDGET_CANDIDATE" "$LIVE_WIDGET"
mv -f -- "$TIMEZONE_CANDIDATE" "$TIMEZONE_TARGET"
mv -f -- "$SESSION_CANDIDATE" "$SESSION_TARGET"

[[ "$(sha256_file "$LIVE_WIDGET")" = "$PATCHED_WIDGET_SHA256" ]] \
	|| die "installed Calendar widget hash verification failed"
[[ "$(sha256_file "$TIMEZONE_TARGET")" = "$TIMEZONE_SHA256" ]] \
	|| die "installed timezone override hash verification failed"
[[ "$(sha256_file "$SESSION_TARGET")" = "$SESSION_SOURCE_SHA" ]] \
	|| die "installed session override hash verification failed"
grep -q 'normalizeFixedOffsetDateTime' "$LIVE_WIDGET" \
	|| die "installed Calendar widget marker is absent"
run_php_lint "$LIVE_WIDGET"
validate_session_source "$SESSION_TARGET" 0
verify_installed_attributes "$LIVE_WIDGET" "$TX_DIR" calendar
verify_installed_attributes "$TIMEZONE_TARGET" "$TX_DIR" timezone
verify_installed_attributes "$SESSION_TARGET" "$TX_DIR" session
run_validation_hook installed "$LIVE_WIDGET" "$TIMEZONE_TARGET" "$SESSION_TARGET"
run_restart_hook
wait_ready || die "readiness check failed after install"

ln -s -- "$TX_ID" "$BACKUP_ROOT/.latest.$$"
mv -Tf -- "$BACKUP_ROOT/.latest.$$" "$BACKUP_ROOT/latest"
TRANSACTION_ACTIVE=0

printf 'Installed the Calendar fixed-offset patch and both PHP overrides.\n'
printf 'Rollback transaction: %s\n' "$TX_DIR"
printf 'No CalDAV object or database content was accessed or changed.\n'
