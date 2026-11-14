# gg_one_do_publish

The publish orchestrator of the gg_one tool family - version bump, changelog, registry upload, merge, tags and resume.

## Publishing several repositories at once

One `DoPublish` may publish several repositories at the same time. Two
entries in the `options` of `DoPublish.exec` are for a caller that does so:
`{waitUntilPublishedOption: false}` skips the wait until the registries
show the new version, and `{uploadExclusivelyOption: <RunExclusively>}`
hands the upload to the caller, who decides when it runs.
