# gg_one_do_publish

The publish orchestrator of the gg_one tool family - version bump, changelog, registry upload, merge, tags and resume.

## Upgrade before publishing

`gg one do publish` upgrades no dependency by default: a release ships the
constraints that were committed and tested. `--upgrade` (`upgrade: true`
from code) runs `dart pub upgrade [--major-versions] --tighten` right
before `can publish` and commits what it changed; `--major-versions` only
when the repository's `.gg/gg_rc` sets `do.upgrade.deps.majorVersions`.
pana does not stand in the way of a release without upgrade: it keeps
granting the points for up-to-date dependencies for 30 days after a new
major version of a dependency.

## Publishing several repositories at once

One `DoPublish` may publish several repositories at the same time. Two
entries in the `options` of `DoPublish.exec` are for a caller that does so:
`{waitUntilPublishedOption: false}` skips the wait until the registries
show the new version, and `{uploadExclusivelyOption: <RunExclusively>}`
hands the upload to the caller, who decides when it runs.
