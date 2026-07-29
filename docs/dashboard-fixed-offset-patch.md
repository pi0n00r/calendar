<!--
SPDX-FileCopyrightText: 2026 Sandeep-Singh Gary Bajaj
SPDX-License-Identifier: AGPL-3.0-or-later
AI-NOTICE:Schema-Version=0.1
AI-NOTICE:License=AGPL-3.0-or-later
AI-NOTICE:Project=calendar
AI-NOTICE:Repository=https://github.com/pi0n00r/calendar
AI-NOTICE:Author=Sandeep-Singh Gary Bajaj
AI-NOTICE:Scope=file
-->

# Reproducible Dashboard fixed-offset patch

The installer packages three related runtime corrections for Calendar 6.5.2:

1. The Dashboard widget preserves the wall clock of timed events whose `TZID`
   is a fixed offset such as `UTC-04:00`. All-day values remain unchanged.
2. PHP receives an explicit `America/Toronto` default timezone.
3. PHP session handling uses a caller-provided protected Redis configuration.

The widget port includes all three commits from upstream Calendar PR #8649.
This fork additionally constructs the fixed offset by concatenating the
regex-validated sign and digit captures with a literal colon. Psalm therefore
infers a `non-empty-string` for `DateTimeZone` without an annotation,
suppression, or configuration change.

The repository does not contain the Redis credential or its fingerprint.
Create the private source from
`resources/php/redis-session.ini.example`, replace the placeholder, and set
the source mode to `0600`. The public timezone template contains SPDX metadata;
the installer deterministically renders the exact one-line runtime payload.

## Plan

The default invocation validates inputs and reports a plan without changing
targets:

```bash
scripts/install-dashboard-fixed-offset-patch.sh \
  --calendar-app-dir /path/to/calendar \
  --timezone-target /path/to/php/conf.d/timezone.ini \
  --session-source /protected/path/redis-session.ini \
  --session-target /path/to/php/conf.d/session.ini \
  --php-validator /path/to/php
```

Install requires both the action and its exact confirmation:

```bash
scripts/install-dashboard-fixed-offset-patch.sh \
  [the plan arguments above] \
  --execute \
  --confirm 'INSTALL CALENDAR PATCH 6.5.2'
```

Use `--restart-hook` to clear OPcache and `--readiness-url` to require service
recovery. Programs and their repeated `--*-arg` options are invoked directly
as argv arrays; command strings are not evaluated.

The installer accepts only Calendar 6.5.2 with the exact official widget or
the exact reviewed patched widget. It preserves uid, gid, projected mode, and
copyable filesystem attributes for every existing target. An absent timezone
target defaults to `0644`; an absent session target defaults to `0600`. Both
modes are configurable. The installer uses the fleet install default
`umask 022` and explicitly applies `0600`/`0700` to protected sources,
temporary material, backups, and metadata.

## Rollback

Each successful install leaves a protected, checksummed transaction below
`--backup-root`. Restore the latest matching transaction with the same target
arguments and:

```bash
--rollback --confirm 'ROLLBACK CALENDAR PATCH 6.5.2'
```

A target that was absent before installation is removed; a pre-existing target
is restored with its prior content and attributes.

Any failure after the first replacement automatically restores all three
components. File restoration and lifecycle recovery are verified separately.
If the rollback restart or readiness check fails, the command exits with
status `2`, reports the protected backup path, and does not claim full
recovery. The installer never reads or writes CalDAV objects or database
content.
