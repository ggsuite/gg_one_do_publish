<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# Tighten the dependency constraints explicitly on publish

## Motivation

- A release has to ship the constraints that were resolved and tested
- Without that, pana rejects the upload for outdated dependencies, and the
  published manifest allows versions nobody ever built against
- So `do publish` upgrades the dependencies right before `can publish`
  (step 5c), with `do upgrade deps` of `gg_one_commit`
- That upgrade always tightened the constraints; now it no longer does by
  default: with local overrides in place pub crashed when it tightened
- Without a change here, a publish would quietly release loose lower
  bounds

## Strategy

- Ask for tightening explicitly, where it is safe: in the publish
- Keep the position of the step, after the `pubspec_overrides.yaml`
  deletion of step 0b and before `can publish`
- Keep the rest of the step as it is
- Pin the explicit call in the tests

## Implementation 1: Pass `tighten: true`

- Step 5c calls `do upgrade deps` with `tighten: true`, which runs
  `dart pub upgrade --major-versions --tighten` (and the node equivalent
  in a hybrid)
- It is safe there: step 0b removed `pubspec_overrides.yaml`, so pub
  resolves against the registry and raises the lower bounds to published
  versions, not to local checkouts
- A comment at the call says why tightening is the publish's job alone
- The content hash around the step decides, as before, whether anything
  changed
- A change is committed as before, as
  `#gg: dart pub upgrade --major-versions --tighten`, which again names
  exactly what ran
- A resumed run and a run with `upgrade: false` still skip the step
- CLAUDE.md explains why the flag has to be passed

## Implementation 2: Tests

- The default mock of the upgrade expects `tighten: true`
- The tests that verify the upgrade call verify `tighten: true`, so a
  publish that drops the flag fails them
- The tests that check that the upgrade is skipped match any `tighten`

## Dependency updates

- `gg_one_commit`: `do upgrade deps` tightens only on request, with the
  new parameter `tighten` and flag `--[no-]tighten`, off by default
- Its mock `MockDoUpgradeDeps` takes `tighten`, so the tests can expect
  the explicit call
- `dna_ggsuite` ^1.0.0 regenerated the guides, skills and `CLAUDE.md`
  block: a `/gg-review` skill, the rules to describe every repo in its own
  terms and to keep every repo in its scope and its `index.jsonc` current,
  and hooks that keep the prompts in the project management repo

## Result

- A release ships tightened constraints, as it did before
- The publish no longer depends on the default of `do upgrade deps`

## Open Points

- Nothing enforces the flag: a new call of the upgrade on the way to a
  release has to remember `tighten: true`
- A caller that turns the step off with `upgrade: false` has to upgrade
  and tighten each repo itself
