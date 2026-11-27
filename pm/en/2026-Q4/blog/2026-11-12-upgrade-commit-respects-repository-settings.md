<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Upgrade commit message respects the repository settings

## Motivation

- `do publish` upgrades and tightens the dependencies before `can publish`
  and records the result in a bookkeeping commit
- That commit always read »dart pub upgrade --major-versions --tighten«
- A repository can forbid crossing majors with
  `do.upgrade.deps.majorVersions: false` in its `.gg/gg_rc`; the commit
  then described an upgrade that never ran

## Strategy

- Ask gg_one_commit's `DoUpgradeDeps.effectiveMajorVersions` — the same
  decision the upgrade itself made — instead of assuming majors
- Name `--major-versions` in the message only when it was used

## Implementation

- New private helper `_upgradeCommitMessage(directory)`
- With majors allowed: »#gg: dart pub upgrade --major-versions --tighten«,
  unchanged
- With majors forbidden: »#gg: dart pub upgrade --tighten«
- A new test covers the forbidden case

## Dependency updates

- gg_one_core: `GgRc`, which reads the repository's `.gg/gg_rc`
- gg_one_commit: `DoUpgradeDeps` follows that setting and exposes
  `effectiveMajorVersions`

## Open Points

- None
