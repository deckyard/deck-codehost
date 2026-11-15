<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# codehost cheatsheet

Every export of `@deckyard/codehost`. Guides are listed in
[the introduction](index.md).

```jennifer
import "@deckyard/codehost/" as codehost;
```

Every verb takes a `Forge` first and throws a `CodehostError` (kind
`"codehost"`, with the HTTP `status` and the `backend`) when it fails; the
generic kinds `"limit"`, `"timeout"`, `"closed"`, `"cancelled"` and `"net"`
(a network failure, a `net.NetError`) pass through as the backend threw them. A `repo` is `owner/name`, or on GitLab a
full path with subgroups (`group/sub/name`) or a numeric id; a `number` is an
issue's or change request's number in its repository (GitLab's `iid`).

## Constants

| Constant | Value | Meaning |
|---|---|---|
| `ERROR_KIND` | `"codehost"` | The `kind` of every error of the deck's own |
| `BACKENDS` | `["github", "gitlab", "forgejo"]` | The backends a `Forge` can hold; Gitea goes through `forgejo` |
| `MERGE_STYLES` | `["merge", "squash", "rebase"]` | The styles `mergeChangeRequest` takes; GitLab refuses `rebase` |
| `STATUS_STATES` | `["pending", "success", "failure", "error"]` | The normalised commit-status states |
| `LABEL_COLOR` | `"#ededed"` | The colour of a label the deck creates on Forgejo for `setIssueLabels` / `addIssueLabels` |

## Types

### `Forge`

A code forge: the backend's name and its client. Only the field of its
backend is set; the client there is the escape hatch for everything this
deck does not cover.

| Field | Meaning |
|---|---|
| `backend as string` | `github`, `gitlab` or `forgejo` |
| `github as github.Client` | the GitHub client |
| `gitlab as gitlab.Client` | the GitLab client |
| `forgejo as forgejo.Client` | the Forgejo (or Gitea) client |

### `CodehostError`

A failed request or a refused value.

| Field | Meaning |
|---|---|
| `kind as string` | always `"codehost"` (`ERROR_KIND`) |
| `message as string` | what failed, starting with who reported it: `github: `, `gitlab: `, `forgejo: ` or `codehost: ` |
| `status as int` | the HTTP status the forge answered; 0 when no answer was read and for a local check |
| `backend as string` | the backend of the `Forge`; "" for a `Forge` built without a constructor |

### `Repository`

| Field | Meaning |
|---|---|
| `fullName as string` | `owner/name`; GitLab's full path |
| `owner as string` | the user, organization or (GitLab) group path |
| `name as string` | the last segment of the path |
| `description as string` | the description |
| `isPrivate as bool` | whether it is not public (GitLab's `internal` counts as private) |
| `isFork as bool` | whether it is a fork |
| `isArchived as bool` | whether it is archived |
| `defaultBranch as string` | e.g. `main` |
| `htmlUrl as string` | its page |
| `cloneUrl as string` | the HTTPS clone URL |
| `sshUrl as string` | the SSH clone URL |
| `stars as int` | the star count |
| `openIssues as int` | open issues; on GitHub pull requests included |
| `updated as string` | last update or activity, RFC 3339 |

### `Issue`

| Field | Meaning |
|---|---|
| `number as int` | the number within the repository (GitLab's `iid`) |
| `title as string` | the title |
| `body as string` | the text, Markdown |
| `state as string` | `open` or `closed` |
| `author as string` | who opened it |
| `labels as list of string` | label names |
| `assignees as list of string` | assigned user names |
| `comments as int` | the comment count, without GitLab's system notes |
| `isChangeRequest as bool` | whether the number is a pull request's (GitHub, Forgejo) |
| `created as string` | RFC 3339 |
| `updated as string` | RFC 3339 |
| `closed as string` | RFC 3339; "" while open |
| `htmlUrl as string` | its page |

### `Comment`

| Field | Meaning |
|---|---|
| `id as int` | the comment (GitLab: note) id |
| `author as string` | who wrote it |
| `body as string` | the text, Markdown |
| `created as string` | RFC 3339 |

### `Label`

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `color as string` | the colour, `#rrggbb` |
| `description as string` | the description |

### `ChangeRequest`

A GitHub or Forgejo pull request, a GitLab merge request.

| Field | Meaning |
|---|---|
| `number as int` | the number within the repository (GitLab's `iid`) |
| `title as string` | the title, without a draft prefix |
| `body as string` | the text, Markdown |
| `state as string` | `open`, `closed` (without merging) or `merged` |
| `author as string` | who opened it |
| `head as string` | the branch with the changes |
| `base as string` | the branch it merges into |
| `headSha as string` | the commit at the head |
| `isDraft as bool` | whether it is a draft |
| `mergeable as bool` | whether the forge would merge it now; false unless open and not a draft, while it is computing that, and in a GitHub listing |
| `mergeSha as string` | the commit the merge left on the base branch; "" until merged |
| `htmlUrl as string` | its page |

### `Asset`

A file attached to a release; on GitLab a release link.

| Field | Meaning |
|---|---|
| `id as int` | the asset (GitLab: link) id |
| `name as string` | the file name |
| `contentType as string` | the media type; "" on GitLab and Forgejo |
| `size as int` | bytes; 0 on GitLab |
| `downloads as int` | the download count; 0 on GitLab |
| `downloadUrl as string` | the link a browser follows |
| `apiUrl as string` | the URL `downloadAsset` reads |

### `Release`

| Field | Meaning |
|---|---|
| `id as int` | the release id; 0 on GitLab |
| `tag as string` | the tag it is for |
| `name as string` | the title |
| `body as string` | the notes, Markdown |
| `isDraft as bool` | whether it is a draft; false on GitLab |
| `isPrerelease as bool` | whether it is a pre-release; false on GitLab |
| `created as string` | RFC 3339 |
| `published as string` | RFC 3339 (GitLab's release date); "" for a draft |
| `htmlUrl as string` | its page |
| `assets as list of Asset` | the attached files |

### `Branch`

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `sha as string` | the commit it points at |
| `isProtected as bool` | whether a protection rule covers it |

### `Tag`

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `sha as string` | the commit it points at |
| `message as string` | the annotation; "" for a lightweight tag and in a GitHub listing; on Forgejo and Gitea a lightweight tag's is its commit's message |

### `Entry`

| Field | Meaning |
|---|---|
| `name as string` | the name |
| `path as string` | the path from the repository root |
| `type as string` | `file`, `dir`, `symlink` or `submodule` |
| `size as int` | bytes; 0 for a directory and on GitLab |
| `sha as string` | the blob or tree SHA |

### `CommitStatus`

| Field | Meaning |
|---|---|
| `context as string` | which check it is, e.g. `ci/build` |
| `state as string` | one of `STATUS_STATES` |
| `forgeState as string` | the state as the forge reported it |
| `description as string` | a short text |
| `targetUrl as string` | where the details are |
| `creator as string` | who set it |
| `created as string` | RFC 3339 |

## Forges

| Function | Returns | Does |
|---|---|---|
| `codehost.connect(backend, host, token)` | `Forge` | a forge by backend name (`github`, `gitlab`, `forgejo`), host and token (`""` for anonymous); no backend import needed |
| `codehost.fromGithub(c)` | `Forge` | a forge on github.com or a GitHub Enterprise Server |
| `codehost.fromGitlab(c)` | `Forge` | a forge on gitlab.com or a self-managed GitLab |
| `codehost.fromForgejo(c)` | `Forge` | a forge on Codeberg, a Forgejo or a Gitea |

## Repositories

| Function | Returns | Does |
|---|---|---|
| `codehost.repository(f, repo)` | `Repository` | one repository |
| `codehost.myRepositories(f)` | `list of Repository` | the repositories the token may reach |

## Issues

| Function | Returns | Does |
|---|---|---|
| `codehost.issues(f, repo, state)` | `list of Issue` | the issues (`open`, `closed`, `all`), newest first, without change requests |
| `codehost.issue(f, repo, number)` | `Issue` | one issue |
| `codehost.createIssue(f, repo, title, body)` | `Issue` | open an issue |
| `codehost.closeIssue(f, repo, number)` | `Issue` | close an issue |
| `codehost.reopenIssue(f, repo, number)` | `Issue` | reopen an issue |
| `codehost.comments(f, repo, number)` | `list of Comment` | an issue's comments, oldest first, without GitLab's system notes |
| `codehost.comment(f, repo, number, body)` | `Comment` | comment on an issue |
| `codehost.labels(f, repo)` | `list of Label` | the labels of a repository |
| `codehost.createLabel(f, repo, name, color, description)` | `Label` | create a label |
| `codehost.setIssueLabels(f, repo, number, names)` | `list of string` | replace an issue's labels, creating missing ones |
| `codehost.addIssueLabels(f, repo, number, names)` | `list of string` | add labels to an issue, creating missing ones |
| `codehost.removeIssueLabel(f, repo, number, name)` |  | take a label off an issue |

## Change requests

| Function | Returns | Does |
|---|---|---|
| `codehost.changeRequests(f, repo, state)` | `list of ChangeRequest` | the change requests (`open`, `closed`, `merged`, `all`), newest first |
| `codehost.changeRequest(f, repo, number)` | `ChangeRequest` | one change request |
| `codehost.createChangeRequest(f, repo, head, base, title, body, isDraft)` | `ChangeRequest` | open a pull or merge request, as a draft or not; a title the forge reads as a draft needs `isDraft` true |
| `codehost.closeChangeRequest(f, repo, number)` | `ChangeRequest` | close it without merging |
| `codehost.reopenChangeRequest(f, repo, number)` | `ChangeRequest` | reopen a closed one |
| `codehost.mergeChangeRequest(f, repo, number, style, deleteBranch)` |  | merge it (`merge`, `squash`, `rebase`), deleting a same-repository head branch on request |
| `codehost.changeRequestComments(f, repo, number)` | `list of Comment` | its conversation, oldest first |
| `codehost.commentChangeRequest(f, repo, number, body)` | `Comment` | comment on it |

## Releases

| Function | Returns | Does |
|---|---|---|
| `codehost.releases(f, repo)` | `list of Release` | the releases, newest first |
| `codehost.release(f, repo, tag)` | `Release` | the release of a tag |
| `codehost.latestRelease(f, repo)` | `Release` | the latest release |
| `codehost.createRelease(f, repo, tag, target, name, body, isPrerelease)` | `Release` | publish a release, creating the tag when needed |
| `codehost.uploadAsset(f, repo, release, name, data)` | `Asset` | attach a file (GitLab: generic package plus a release link) |
| `codehost.downloadAsset(f, asset, maxBytes)` | `bytes` | download an asset stored on the forge, with the token |

## Branches and tags

| Function | Returns | Does |
|---|---|---|
| `codehost.branches(f, repo)` | `list of Branch` | the branches |
| `codehost.createBranch(f, repo, name, from)` | `Branch` | create a branch; `from` "" for the default branch |
| `codehost.deleteBranch(f, repo, name)` |  | delete a branch |
| `codehost.tags(f, repo)` | `list of Tag` | the tags |
| `codehost.createTag(f, repo, name, target, message)` | `Tag` | create a lightweight or annotated tag |
| `codehost.deleteTag(f, repo, name)` |  | delete a tag |

## Files

| Function | Returns | Does |
|---|---|---|
| `codehost.readFile(f, repo, path, ref, maxBytes)` | `bytes` | a file's content, up to `maxBytes` (0 for 64 MiB, negative for no limit) |
| `codehost.writeFile(f, repo, path, data, message, branch)` | `string` | create or replace a file with a commit; the commit SHA |
| `codehost.deleteFile(f, repo, path, message, branch)` | `string` | delete a file with a commit; the commit SHA |
| `codehost.listDirectory(f, repo, path, ref)` | `list of Entry` | the entries of a directory |

## Commit statuses

| Function | Returns | Does |
|---|---|---|
| `codehost.setCommitStatus(f, repo, sha, state, context, description, targetUrl)` | `CommitStatus` | set a status on a commit |
| `codehost.commitStatuses(f, repo, sha)` | `list of CommitStatus` | every status set on a commit, newest first |
