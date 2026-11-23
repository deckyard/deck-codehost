<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Releases, files and statuses

Snippets assume a forge `$f` built as in [the introduction](index.md) and
the import `import "@deckyard/codehost/" as codehost;`.

## Releases

```jennifer
def latest as codehost.Release init codehost.latestRelease($f, "me/app");
for (def a in $latest.assets) {
    io.printf("%s %s\n", $a.name, $a.downloadUrl);
}
```

`latestRelease` is, on GitHub and Forgejo, the newest release that is
neither a draft nor a pre-release, on GitLab the one with the latest
release date that is not in the future. `release` finds one by its tag,
`releases` lists them newest first.

A release script:

```jennifer
def r as codehost.Release init codehost.createRelease(
    $f, "me/app", "1.3.0", "", "1.3.0", "What changed ...", false);
codehost.uploadAsset($f, "me/app", $r, "app-1.3.0.tar.gz", $tarball);
```

`createRelease` creates the tag at `target` when it does not exist yet; ""
is the default branch. GitLab has no pre-releases and refuses
`isPrerelease`; GitLab releases have no id (the tag is the key), so
`Release.id` is 0 there.

`uploadAsset` takes the `Release` (GitHub and Forgejo address it by id,
GitLab by tag). On GitLab a release asset is a link: the deck uploads the
file to the project's generic package registry as
`<project>/<tag>/<name>` and attaches a `package` link to it, so it is kept
and downloadable with the token like on the other forges. There the tag and
the file name are letters, digits and `._+-` (the name also `~@`).

```jennifer
def data as bytes init codehost.downloadAsset($f, $latest.assets[0], 0);
```

`downloadAsset` reads `Asset.apiUrl` with the client's token, up to
`maxBytes` (0 for 64 MiB, a negative value for no limit; over it is kind
`"limit"`). The token only goes to the forge's own address: GitHub answers
with a redirect to its storage host, followed without it; an asset whose
URL lies elsewhere is refused, which on GitLab means a link to another site
or a CI artifact. Fetch that `downloadUrl` yourself, without the token.

## Branches and tags

```jennifer
codehost.createBranch($f, "me/app", "release-1.3", "");
codehost.createTag($f, "me/app", "1.3.0", "release-1.3", "Release 1.3.0");
for (def t in codehost.tags($f, "me/app")) {
    io.printf("%s %s\n", $t.name, $t.sha);
}
codehost.deleteBranch($f, "me/app", "release-1.3");
```

`from` and `target` take a branch, tag or commit; "" is the default
branch. A `message` makes an annotated tag, "" a lightweight one. GitHub's
tag listing carries no annotations, so `Tag.message` is "" there; Forgejo
and Gitea give a lightweight tag its commit's message.

## Files

```jennifer
def text as string init encoding.decode("utf-8", codehost.readFile($f, "me/app", "VERSION", "", 4096));
def sha as string init codehost.writeFile($f, "me/app", "VERSION", encoding.encode("utf-8", "1.3.0\n"),
    "bump the version", "main");
codehost.deleteFile($f, "me/app", "old.txt", "drop old.txt", "main");
for (def e in codehost.listDirectory($f, "me/app", "docs", "")) {
    io.printf("%s %s\n", $e.type, $e.path);
}
```

`readFile` reads up to `maxBytes`, as `downloadAsset`: 0 for 64 MiB, a
negative value for no limit, over it is kind `"limit"`. GitHub refuses a
cap over 100 MB (its raw limit); the forgejo deck reads at most 64 MiB
whatever the cap.

`writeFile` creates or replaces the file with a commit of its own and
answers with the commit's SHA; `deleteFile` likewise. A file in Git LFS
reads as its content on GitLab and Forgejo, as the pointer on GitHub.
`listDirectory` names entry types `file`, `dir`, `symlink` and
`submodule` on every forge. GitHub's contents listing calls a symlink and a
submodule a `file`, so there the deck reads the directory's git tree
instead: two requests, the parent directory's listing (or, for the root,
the newest commit on the ref) and the tree. GitLab does not list sizes, so
`Entry.size` is 0 there.

## Commit statuses

```jennifer
codehost.setCommitStatus($f, "me/app", $sha, "pending", "ci/build", "building", $logUrl);
codehost.setCommitStatus($f, "me/app", $sha, "success", "ci/build", "built in 42 s", $logUrl);
for (def s in codehost.commitStatuses($f, "me/app", $sha)) {
    io.printf("%s %s (%s)\n", $s.context, $s.state, $s.forgeState);
}
```

The states are `pending`, `success`, `failure` and `error`
(`STATUS_STATES`). GitLab has its own set: `failure` is set there as
`failed`, `error` as `canceled`, and read back the other way;
`running` and the other waiting states read as `pending`, `skipped` as
`success`. Forgejo's `warning` reads as `success` (finished, not failed).
`forgeState` keeps what the forge said. GitLab refuses some moves, such as `success` back to
`pending` (HTTP 400). `commitStatuses` lists every status set on the commit,
newest first, earlier ones of a context included.
