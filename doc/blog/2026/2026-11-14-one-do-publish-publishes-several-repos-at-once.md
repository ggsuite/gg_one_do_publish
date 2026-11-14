<!--
@license
Copyright (c) ggsuite

Use of this source code is governed by terms that can be
found in the LICENSE file in the root of this package.
-->

# One DoPublish publishes several repos at once

## Motivation

- `DoPublish` was written for one repository at a time: call `exec`, wait
  until the release is done, call it for the next one
- A caller that releases several repositories may want to run them side
  by side with one `DoPublish`. Three things stood in the way:
  - the command kept the version increment and the release channel of
    the run in two fields. A second run overwrote the answers of the
    first
  - every run waited until the registries showed its upload, up to 15
    minutes, even when nothing resolves against that version next
  - an upload can own the terminal: npm asks for a one-time password
    there. Two uploads asking at once would be unusable
- The goal: one instance, several runs, each with its own answers, and
  the caller decides about the two steps only it can judge

## Strategy

- Keep what a run resolved up front per directory, not per command
- Leave the decisions about the wait and about the turn of the upload to
  the caller, as options of `exec`
- Pass both through the `options` map, the way `panaOption` travels
  already. `exec` keeps its signature; `get` takes the two values as the
  optional parameters `waitUntilPublished` and `uploadExclusively`
- Without the options, and on the command line, everything stays as it
  was: the publish waits, and the upload starts right away

## The answers of a run are kept per directory

- The fields `_explicitVersionIncrement` and `_explicitChannel` are gone
- `_resolved` maps the directory of a run to its pre-resolved increment
  and channel. It is filled before the steps of that run start
- The version bump and the version tag of a project without a manifest
  read the entry of their own directory
- The collaborators of `DoPublish` hold no state of a run, so one
  instance can serve several directories at the same time

## The registry wait can be turned off

- After the upload `do publish` waits until the registries show the new
  version (gg_publish's `WaitUntilPublished`)
- The wait only matters to whoever resolves against that version next.
  The tag step that follows needs git only
- New option `waitUntilPublishedOption`: `{waitUntilPublishedOption:
  false}` in the `options` of `exec` skips the wait
- A caller that publishes several packages turns it off for a package
  nothing published after it depends on, and waits for all such versions
  at once when it is done. `WaitUntilPublished` can run at any later time
- A merge-only run uploads nothing and never waited

## The upload can wait for its turn

- New option `uploadExclusivelyOption`. It holds a `RunExclusively`: a
  function that gets the upload as a body, runs it when it is its turn
  and completes when the body did
- The caller passes a function that lets one upload through at a time, so
  only one upload talks to the terminal
- The whole upload of a repository is one body: a hybrid package uploads
  to pub.dev and npm in the same turn, and each registry is still marked
  done between the two uploads
- Without the option the upload starts right away

## Tests

- The publish completes, tag included, without a call of
  `WaitUntilPublished` when the wait is turned off
- The upload starts only inside the function the caller passed and is
  done when that function returns

## Open Points

- Both options exist for callers of `exec` only; the command line has no
  flag for them
- A caller that turns the wait off has to wait itself before anything
  resolves against the new version
- The entry of a run stays in `_resolved` after the run; the next run in
  the same directory replaces it
- Two runs for the same directory at the same time would share one entry.
  Nothing guards against that
