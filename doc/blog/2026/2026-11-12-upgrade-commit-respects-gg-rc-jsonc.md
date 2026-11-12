<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Upgrade commit message respects .gg/gg_rc.jsonc

## Motivation

- `do publish` upgrades and tightens the dependencies before `can publish`
  and records the result in a bookkeeping commit
- That commit always read »dart pub upgrade --major-versions --tighten«
- A repository can forbid crossing majors with
  `upgradeMajorVersions: false` in `.gg/gg_rc.jsonc`; the commit then
  described an upgrade that never ran

## Strategy

- Read the setting with `RepoGgRc.read` from gg_one_core, which never creates
  the file
- Name `--major-versions` in the message only when the setting allows it

## Implementation

- New private helper `_upgradeCommitMessage(directory)`
- With majors allowed: »#gg: dart pub upgrade --major-versions --tighten«,
  unchanged
- With majors forbidden: »#gg: dart pub upgrade --tighten«
- A new test covers the forbidden case

## Dependency updates

- gg_one_core: `RepoGgRc`, the reader of `.gg/gg_rc.jsonc`

## Open Points

- None
