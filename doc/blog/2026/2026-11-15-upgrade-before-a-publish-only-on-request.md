<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Upgrade before a publish only on request

## Motivation

- `gg one do publish` upgraded the dependencies right before `can publish`:
  `dart pub upgrade --major-versions --tighten`, committed as a `#gg:`
  system commit
- So every release could ship constraints nobody had built and tested
  against — major versions included — and paid for the resolution
- A release should ship the constraints that were committed and tested.
  New versions of the dependencies belong to a maintenance run of their own

## Strategy

- Keep the upgrade step, but turn it around: off by default, on with
  `--upgrade` or `upgrade: true`
- Leave its position and its commit unchanged for the case it is asked for
- Check that pana does not reject a release without upgrade

## Off by default

- The flag `--upgrade` now defaults to `false`; `--no-upgrade` still parses
- The parameter `upgrade` of `exec`/`get` falls back to the flag, so a
  caller from code that passes nothing gets no upgrade either
- With `upgrade: true` everything works as before: after the
  `pubspec_overrides.yaml` deletion, before `can publish`, and a commit only
  when the content hash changed
- Whether the upgrade crosses major versions is still the repository's
  `do.upgrade.deps.majorVersions` — now `false` by default

## pana stays green

- pana's section »Support up-to-date dependencies« awards its points as
  long as the constraints allow the newest stable versions
- A new major version of a dependency costs no points for 30 days after it
  was released (`acceptableUpdateDelay` in pana 0.22.23)
- A release without upgrade therefore passes pana as long as the
  dependencies are raised regularly

## Tests

- Without a flag no upgrade runs, programmatically and on the command line
- `--upgrade` and `upgrade: true` run it before `can publish`
- The upgrade commit names `--major-versions` only when `.gg/gg_rc` allows
  them; an upgrade that changes nothing writes no commit

## Open Points

- A dependency whose new major version is older than 30 days and was not
  raised yet makes pana fail; `--upgrade` or a maintenance run fixes it
