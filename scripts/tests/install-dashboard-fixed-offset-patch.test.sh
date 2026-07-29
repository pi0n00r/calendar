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
umask 077

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install-dashboard-fixed-offset-patch.sh"
OFFICIAL_FIXTURE="$TEST_DIR/fixtures/CalendarWidget-6.5.2.official.php"
OFFICIAL_SHA256="5f6a67cd3c3bb86eb5f80e36c3baad2f85a877e9300e24a7d08c968529cdf460"
PATCHED_SHA256="9abec8e540d36a5c83d23f2a1c448dd899637328f50af1e0f3a26fddd2077e56"
TIMEZONE_SHA256="dddf840ec90da392ddce5f577d736f8cb94f85246936f879218749535356bd09"
INSTALL_CONFIRMATION="INSTALL CALENDAR PATCH 6.5.2"
ROLLBACK_CONFIRMATION="ROLLBACK CALENDAR PATCH 6.5.2"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/calendar-installer-tests.XXXXXX")"
trap 'rm -rf -- "$ROOT"' EXIT
PASS=0

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local message="$3"
	[[ "$actual" = "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

assert_file_sha() {
	local expected="$1"
	local file="$2"
	local message="$3"
	[[ -f "$file" ]] || fail "$message: file is absent"
	assert_eq "$expected" "$(sha256sum "$file" | awk '{print $1}')" "$message"
}

assert_failure() {
	if "$@" >"$ROOT/failure.stdout" 2>"$ROOT/failure.stderr"; then
		fail "command unexpectedly succeeded: $*"
	fi
}

assert_failure_rc() {
	local expected_rc="$1"
	shift
	local actual_rc
	set +e
	"$@" >"$ROOT/failure.stdout" 2>"$ROOT/failure.stderr"
	actual_rc=$?
	set -e
	[[ "$actual_rc" -ne 0 ]] || fail "command unexpectedly succeeded: $*"
	assert_eq "$expected_rc" "$actual_rc" "failure exit status"
}

new_case() {
	local name="$1"
	local directory="$ROOT/$name"
	rm -rf -- "$directory"
	mkdir -p "$directory"
	printf '%s\n' "$directory"
}

make_app() {
	local directory="$1"
	local version="${2:-6.5.2}"
	mkdir -p "$directory/appinfo" "$directory/lib/Dashboard"
	cat >"$directory/appinfo/info.xml" <<EOF
<?xml version="1.0"?>
<info>
	<id>calendar</id>
	<version>$version</version>
</info>
EOF
	cp -- "$OFFICIAL_FIXTURE" "$directory/lib/Dashboard/CalendarWidget.php"
	chmod 0640 "$directory/lib/Dashboard/CalendarWidget.php"
}

make_session_source() {
	local file="$1"
	cat >"$file" <<'EOF'
session.save_handler = redis
session.save_path = "tcp://redis:6379?auth=test-only-nonproduction-secret"
session.gc_maxlifetime = 604800
session.cookie_lifetime = 604800
redis.session.locking_enabled = 1
redis.session.lock_retries = -1
redis.session.lock_wait_time = 10000
redis.session.early_refresh = 1
EOF
	chmod 0600 "$file"
}

make_fake_php() {
	local file="$1"
	cat >"$file" <<'EOF'
#!/usr/bin/env bash
set -eu
[ "$1" = "-l" ]
grep -q '^<?php' "$2"
EOF
	chmod 0755 "$file"
}

make_fail_once_restart() {
	local file="$1"
	cat >"$file" <<'EOF'
#!/usr/bin/env bash
set -eu
marker="$1"
if [ ! -e "$marker" ]; then
	touch "$marker"
	exit 1
fi
EOF
	chmod 0755 "$file"
}

common_args() {
	local case_dir="$1"
	printf '%s\0' \
		--calendar-app-dir "$case_dir/calendar" \
		--timezone-target "$case_dir/conf/timezone.ini" \
		--session-source "$case_dir/private/session.ini" \
		--session-target "$case_dir/conf/session.ini" \
		--backup-root "$case_dir/backups" \
		--php-validator "$ROOT/fake-php"
}

run_installer() {
	local case_dir="$1"
	shift
	local args=()
	while IFS= read -r -d '' item; do
		args+=("$item")
	done < <(common_args "$case_dir")
	"$INSTALLER" "${args[@]}" "$@"
}

test_help() {
	local help
	help="$("$INSTALLER" --help)"
	grep -q -- '--rollback' <<<"$help"
	grep -q -- "$INSTALL_CONFIRMATION" <<<"$help"
	grep -q -- "$ROLLBACK_CONFIRMATION" <<<"$help"
}

test_plan_does_not_mutate() {
	local case_dir
	local before_widget before_timezone before_session
	case_dir="$(new_case plan)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"
	printf 'prior timezone\n' >"$case_dir/conf/timezone.ini"
	printf 'prior session\n' >"$case_dir/conf/session.ini"
	before_widget="$(sha256sum "$case_dir/calendar/lib/Dashboard/CalendarWidget.php")"
	before_timezone="$(sha256sum "$case_dir/conf/timezone.ini")"
	before_session="$(sha256sum "$case_dir/conf/session.ini")"

	run_installer "$case_dir" >/dev/null

	assert_eq "$before_widget" "$(sha256sum "$case_dir/calendar/lib/Dashboard/CalendarWidget.php")" "plan widget"
	assert_eq "$before_timezone" "$(sha256sum "$case_dir/conf/timezone.ini")" "plan timezone"
	assert_eq "$before_session" "$(sha256sum "$case_dir/conf/session.ini")" "plan session"
	[[ ! -e "$case_dir/backups" ]] || fail "plan created backup material"
}

test_confirmation_gates() {
	local case_dir
	case_dir="$(new_case confirmations)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"

	assert_failure run_installer "$case_dir" --execute
	[[ ! -e "$case_dir/backups" ]] || fail "bare execute created backup material"
	assert_failure run_installer "$case_dir" --execute --confirm "WRONG"
	[[ ! -e "$case_dir/backups" ]] || fail "wrong execute confirmation created backup material"
}

test_install_idempotency_modes_and_present_rollback() {
	local case_dir
	local count_before count_after
	local transaction_dir
	local protected_file
	case_dir="$(new_case present)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"
	printf 'date.timezone = "UTC"\n' >"$case_dir/conf/timezone.ini"
	printf 'old protected session\n' >"$case_dir/conf/session.ini"
	chmod 0770 "$case_dir/conf/timezone.ini" "$case_dir/conf/session.ini"

	run_installer "$case_dir" --execute --confirm "$INSTALL_CONFIRMATION" >/dev/null

	assert_file_sha "$PATCHED_SHA256" "$case_dir/calendar/lib/Dashboard/CalendarWidget.php" "installed widget"
	assert_file_sha "$TIMEZONE_SHA256" "$case_dir/conf/timezone.ini" "installed timezone"
	assert_file_sha "$(sha256sum "$case_dir/private/session.ini" | awk '{print $1}')" \
		"$case_dir/conf/session.ini" "installed session"
	assert_eq "640" "$(stat -c '%a' "$case_dir/calendar/lib/Dashboard/CalendarWidget.php")" "widget mode preservation"
	assert_eq "770" "$(stat -c '%a' "$case_dir/conf/timezone.ini")" "timezone mode preservation"
	assert_eq "770" "$(stat -c '%a' "$case_dir/conf/session.ini")" "session mode preservation"
	transaction_dir="$case_dir/backups/$(readlink "$case_dir/backups/latest")"
	assert_eq "700" "$(stat -c '%a' "$case_dir/backups")" "backup root mode"
	assert_eq "700" "$(stat -c '%a' "$transaction_dir")" "backup transaction mode"
	for protected_file in \
		CalendarWidget.php \
		timezone-override.ini \
		session-override.ini \
		metadata \
		metadata.sha256
	do
		assert_eq "600" "$(stat -c '%a' "$transaction_dir/$protected_file")" \
			"protected backup mode for $protected_file"
	done
	count_before="$(find "$case_dir/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)"

	run_installer "$case_dir" --execute --confirm "$INSTALL_CONFIRMATION" >/dev/null
	count_after="$(find "$case_dir/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)"
	assert_eq "$count_before" "$count_after" "idempotent backup count"

	assert_failure run_installer "$case_dir" --rollback
	assert_failure run_installer "$case_dir" --rollback --confirm "WRONG"
	run_installer "$case_dir" --rollback --confirm "$ROLLBACK_CONFIRMATION" >/dev/null
	assert_file_sha "$OFFICIAL_SHA256" "$case_dir/calendar/lib/Dashboard/CalendarWidget.php" "rolled-back widget"
	assert_eq 'date.timezone = "UTC"' "$(cat "$case_dir/conf/timezone.ini")" "timezone rollback content"
	assert_eq "old protected session" "$(cat "$case_dir/conf/session.ini")" "session rollback content"
	assert_eq "770" "$(stat -c '%a' "$case_dir/conf/timezone.ini")" "timezone rollback mode"
	assert_eq "770" "$(stat -c '%a' "$case_dir/conf/session.ini")" "session rollback mode"
}

test_absent_targets_install_defaults_and_rollback() {
	local case_dir
	case_dir="$(new_case absent)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"

	run_installer "$case_dir" --execute --confirm "$INSTALL_CONFIRMATION" >/dev/null

	assert_eq "644" "$(stat -c '%a' "$case_dir/conf/timezone.ini")" "new timezone mode"
	assert_eq "600" "$(stat -c '%a' "$case_dir/conf/session.ini")" "new session mode"
	run_installer "$case_dir" --rollback --confirm "$ROLLBACK_CONFIRMATION" >/dev/null
	[[ ! -e "$case_dir/conf/timezone.ini" ]] || fail "rollback retained formerly absent timezone"
	[[ ! -e "$case_dir/conf/session.ini" ]] || fail "rollback retained formerly absent session"
	assert_file_sha "$OFFICIAL_SHA256" "$case_dir/calendar/lib/Dashboard/CalendarWidget.php" "absent rollback widget"
}

test_version_and_hash_rejection() {
	local case_dir
	case_dir="$(new_case rejection)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar" 6.5.3
	make_session_source "$case_dir/private/session.ini"
	assert_failure run_installer "$case_dir"
	[[ ! -e "$case_dir/backups" ]] || fail "version rejection created backups"

	make_app "$case_dir/calendar" 6.5.2
	printf '\n// drift\n' >>"$case_dir/calendar/lib/Dashboard/CalendarWidget.php"
	assert_failure run_installer "$case_dir"
	[[ ! -e "$case_dir/backups" ]] || fail "hash rejection created backups"
}

test_failed_post_check_restores_all_components() {
	local case_dir
	local timezone_before session_before
	case_dir="$(new_case automatic-rollback)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"
	printf 'date.timezone = "UTC"\n' >"$case_dir/conf/timezone.ini"
	printf 'old protected session\n' >"$case_dir/conf/session.ini"
	chmod 0770 "$case_dir/conf/timezone.ini" "$case_dir/conf/session.ini"
	timezone_before="$(sha256sum "$case_dir/conf/timezone.ini" | awk '{print $1}')"
	session_before="$(sha256sum "$case_dir/conf/session.ini" | awk '{print $1}')"

	make_fail_once_restart "$case_dir/fail-once-restart"
	assert_failure run_installer "$case_dir" \
		--execute --confirm "$INSTALL_CONFIRMATION" \
		--restart-hook "$case_dir/fail-once-restart" \
		--restart-arg "$case_dir/restart.marker"

	assert_file_sha "$OFFICIAL_SHA256" "$case_dir/calendar/lib/Dashboard/CalendarWidget.php" "automatic widget rollback"
	assert_file_sha "$timezone_before" "$case_dir/conf/timezone.ini" "automatic timezone rollback"
	assert_file_sha "$session_before" "$case_dir/conf/session.ini" "automatic session rollback"
	assert_eq "770" "$(stat -c '%a' "$case_dir/conf/timezone.ini")" "automatic timezone mode rollback"
	assert_eq "770" "$(stat -c '%a' "$case_dir/conf/session.ini")" "automatic session mode rollback"
	grep -q 'verified lifecycle recovery' "$ROOT/failure.stderr" \
		|| fail "successful rollback lifecycle recovery was not reported"
}

test_failed_rollback_lifecycle_is_fail_closed() {
	local case_dir
	local timezone_before session_before
	case_dir="$(new_case rollback-lifecycle-failure)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"
	printf 'date.timezone = "UTC"\n' >"$case_dir/conf/timezone.ini"
	printf 'old protected session\n' >"$case_dir/conf/session.ini"
	chmod 0770 "$case_dir/conf/timezone.ini" "$case_dir/conf/session.ini"
	timezone_before="$(sha256sum "$case_dir/conf/timezone.ini" | awk '{print $1}')"
	session_before="$(sha256sum "$case_dir/conf/session.ini" | awk '{print $1}')"

	assert_failure_rc 2 run_installer "$case_dir" \
		--execute --confirm "$INSTALL_CONFIRMATION" \
		--restart-hook /bin/false

	assert_file_sha "$OFFICIAL_SHA256" "$case_dir/calendar/lib/Dashboard/CalendarWidget.php" "failed lifecycle widget restore"
	assert_file_sha "$timezone_before" "$case_dir/conf/timezone.ini" "failed lifecycle timezone restore"
	assert_file_sha "$session_before" "$case_dir/conf/session.ini" "failed lifecycle session restore"
	grep -q 'restored all files, but lifecycle recovery failed' "$ROOT/failure.stderr" \
		|| fail "failed rollback lifecycle was not reported"
	grep -q 'inspect protected backup:' "$ROOT/failure.stderr" \
		|| fail "failed rollback lifecycle omitted backup path"
	if grep -q 'verified lifecycle recovery' "$ROOT/failure.stderr"; then
		fail "failed rollback lifecycle falsely reported recovery"
	fi
}

test_protected_source_mode_and_secret_redaction() {
	local case_dir
	local secret="must-not-appear-in-output"
	case_dir="$(new_case source-mode)"
	mkdir -p "$case_dir/conf" "$case_dir/private"
	make_app "$case_dir/calendar"
	make_session_source "$case_dir/private/session.ini"
	sed -i "s/test-only-nonproduction-secret/$secret/" "$case_dir/private/session.ini"
	chmod 0644 "$case_dir/private/session.ini"

	assert_failure run_installer "$case_dir"
	if grep -R -- "$secret" "$ROOT/failure.stdout" "$ROOT/failure.stderr"; then
		fail "protected Redis credential appeared in output"
	fi
}

assert_file_sha "$OFFICIAL_SHA256" "$OFFICIAL_FIXTURE" "official test fixture"
assert_file_sha "$PATCHED_SHA256" "$REPO_ROOT/lib/Dashboard/CalendarWidget.php" "patched source fixture"
make_fake_php "$ROOT/fake-php"

for test_name in \
	test_help \
	test_plan_does_not_mutate \
	test_confirmation_gates \
	test_install_idempotency_modes_and_present_rollback \
	test_absent_targets_install_defaults_and_rollback \
	test_version_and_hash_rejection \
	test_failed_post_check_restores_all_components \
	test_failed_rollback_lifecycle_is_fail_closed \
	test_protected_source_mode_and_secret_redaction
do
	"$test_name"
	PASS=$((PASS + 1))
	printf 'ok %d - %s\n' "$PASS" "$test_name"
done

printf '1..%d\n' "$PASS"
