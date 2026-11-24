<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# @deckyard/codehost

One API over the code forges, so a release script or a triage bot runs
against GitHub™, GitLab™ and Forgejo™ (and Gitea™) alike: repositories, issues,
change requests (pull and merge requests), releases and their assets,
branches, tags, files and commit statuses. It is a facade over three decks,
[`@deckyard/github`](https://deckyard.github.io/deck-github/),
[`@deckyard/gitlab`](https://deckyard.github.io/deck-gitlab/) and
[`@deckyard/forgejo`](https://deckyard.github.io/deck-forgejo/), which do the
talking; this deck picks the verb of the right one and makes the answers
look the same.

Only the common denominator is here. What one forge alone has (GitHub
Actions and secrets, GitLab pipelines, groups and approvals, webhooks,
milestones, reviews, GraphQL™) stays in the backend decks: see
[Beyond the common verbs](#beyond-the-common-verbs).

- [Issues and change requests](issues.md): issues, comments, labels, pull
  and merge requests, merging
- [Releases, files and statuses](releases.md): releases and assets,
  branches and tags, files, commit statuses
- [Cheatsheet](cheatsheet.md): every export

## Conventions

Snippets assume this import:

```jennifer
import "@deckyard/codehost/" as codehost;
```

`jvc add @deckyard/codehost` vendors the three backend decks too. A program
imports one of them only to build a client with settings `connect` does not
take (see below).

## The Forge

A `Forge` holds the backend's name and that backend's client. `connect`
builds one from the backend's name, a host and a token (`""` for
anonymous), so the backend can come from a configuration file:

```jennifer
def gh as codehost.Forge init codehost.connect("github", "github.com", $token);
def gl as codehost.Forge init codehost.connect("gitlab", "gitlab.example.com", $token);
def fj as codehost.Forge init codehost.connect("forgejo", "codeberg.org", "");
```

For a CA certificate, timeouts, retries or plain http on a LAN, build the
client with the backend deck as it describes and wrap it with `fromGithub`,
`fromGitlab` or `fromForgejo`; that program imports the backend deck too:

```jennifer
import "@deckyard/gitlab/" as gitlab;

def c as gitlab.Client init gitlab.withTimeout(gitlab.withToken(gitlab.client("git.lan"), $token), 60000);
def gl as codehost.Forge init codehost.fromGitlab($c);
```

The github and forgejo decks refuse plain `http://` to another machine than
this one unless the client has `withPlainHttp`, so `connect` with such an
address fails at the first request:
`codehost.fromForgejo(forgejo.withPlainHttp(forgejo.client("http://git.lan:3000")))`.

Every verb then takes the forge first, and the rest in the order the
backend decks use where they agree:

```jennifer
for (def f in [$gh, $gl, $fj]) {
    def r as codehost.Release init codehost.latestRelease($f, "me/app");
    io.printf("%s: %s\n", $f.backend, $r.tag);
}
```

- `repo` is `owner/name`. On GitLab it is the project's full path with its
  subgroups (`group/sub/app`) or its numeric id.
- `number` is an issue's or change request's number in its repository, as
  the web pages show it (GitLab's `iid`, never its instance-wide `id`).
- A branch, tag or ref of `""` means the default branch, on every forge
  (the deck looks it up where GitLab wants it named).

Gitea speaks Forgejo's API: connect to it as `forgejo` (or wrap a
`forgejo.client` with `fromForgejo`). Every write verb was run against
Gitea 1.24.

## What is normalised

| Concept | GitHub | GitLab | Forgejo | This deck |
|---|---|---|---|---|
| issue state | `open`, `closed` | `opened`, `closed` | `open`, `closed` | `open`, `closed` |
| change request state | `open`, `closed` + `merged` flag | `opened`, `locked`, `closed`, `merged` | `open`, `closed` + `merged` flag | `open`, `closed` (not merged), `merged`; `locked` is `open` |
| change request number | `number` | `iid` | `number` | `number` |
| draft | `draft` member | `Draft:`, `[Draft]`, `(Draft)` title prefix + `draft` | `WIP:`, `[WIP]` title prefix (`draft` member on newer releases) | `isDraft`; the prefix is taken off `title`; a draft is never `mergeable` |
| merge commit | test merge commit while open | none for a fast-forward | set when merged | `mergeSha`: what landed on the base branch, "" until merged |
| commit-status states | `pending`, `success`, `failure`, `error` | `pending`, `running`, `success`, `failed`, `canceled`, `skipped`, ... | `pending`, `success`, `failure`, `error`, `warning` | `pending`, `success`, `failure`, `error` (`forgeState` keeps the original) |
| release asset | an asset | a release link (to a generic package) | an attachment | an `Asset`; `uploadAsset` makes the package and the link on GitLab |
| release id | id | none, the tag is the key | id | `id`, 0 on GitLab |
| labels on an issue | names, created when missing | names, created when missing | names of existing repository or organization labels; others are dropped | names, created when missing everywhere |
| comments | issue comments | notes, system notes among them | issue comments | `Comment`; GitLab's system notes left out |
| directory entry types | `file`, `dir`; a symlink or submodule is listed as `file`, the git tree has the modes | `blob`, `tree`, `commit` | `file`, `dir`, `symlink`, `submodule` | as Forgejo (a git blob of mode `120000` is a `symlink`); GitHub is read from the directory's git tree, one request more |

The commit-status mapping in detail: GitLab's `running`, `created`,
`manual` and the other waiting states read as `pending`, `failed` as
`failure`, `canceled` as `error`, `skipped` as `success`; Forgejo's
`warning` (the check finished with warnings) and `skipped` read as
`success`, as GitLab's success with warnings does, and `forgeState` keeps
`warning` for a caller that wants it to block; an unknown state reads as
`pending`. Set on GitLab, `failure` becomes `failed` and `error` becomes
`canceled`.

## Where the forges differ

Some differences cannot be smoothed over without guessing; this is what the
deck decided.

- **Merge styles.** `merge`, `squash` and `rebase` work on GitHub and
  Forgejo. GitLab chooses between a merge commit and a fast-forward by the
  project's merge method, not per merge: `merge` merges with that method,
  `squash` squashes first, `rebase` is refused (`CodehostError`, status 0,
  nothing sent).
- **Deleting the branch after a merge.** `deleteBranch` deletes the head
  branch only when it lives in the same repository; a fork's branch is
  never touched, on any forge (the deck reads the change request first to
  tell). A branch the forge deletes by its own setting (GitHub's
  "automatically delete head branches", a GitLab merge request opened with
  "delete source branch") is deleted either way. GitLab deletes it in the
  background, a moment after the merge returns.
- **Labels.** `setIssueLabels` and `addIssueLabels` create a missing label
  on every forge. GitHub and GitLab do that themselves; Forgejo drops a name
  it has no repository or organization label for, so the deck creates those
  in `LABEL_COLOR` and adds them. GitLab refuses a label name with a comma.
  `removeIssueLabel` of a label the issue does not have is a 404 on GitHub
  and no error elsewhere; on Forgejo and Gitea the deck reads the issue's
  labels for the id (Gitea takes no name). `labels` lists a GitLab project's
  group labels, but not a Forgejo organization's.
- **Drafts.** `createChangeRequest(..., true)` opens a draft on GitHub, and
  on GitLab and Forgejo puts `Draft: ` or `WIP: ` in front of the title,
  which is how they mark one. A title with a prefix that forge reads as a
  draft keeps it (GitLab: `Draft:`, `[Draft]`, `(Draft)`; Forgejo and
  Gitea: `WIP:`, `[WIP]`, any case); another forge's prefix does not count
  (GitLab no longer reads `WIP:`, Forgejo never read `Draft:`). With
  `isDraft` false such a title is refused (status 0, before any request),
  since that forge would open a draft anyway; another forge's prefix is
  ordinary text.
- **Numbers** below 1 are refused before anything is sent, on every forge.
- **Pre-releases.** GitLab has none: `createRelease(..., true)` is refused
  there. Its upcoming releases (a release date in the future) are not
  drafts either; `isDraft` is false on GitLab.
- **Asset downloads.** `downloadAsset` sends the client's token to the
  forge's own address only. GitHub's redirect to its storage host is
  followed without it; an asset whose URL lies elsewhere (common for a
  GitLab release link to a CI artifact or another site) is refused: fetch
  its `downloadUrl` with `http` yourself, without the token.
- **Asset uploads on GitLab** go to the project's generic package registry
  as `<project>/<tag>/<name>` (`<project>` the last segment of the path),
  then a `package` link is added, as `glab` does it. The tag and the file
  name must then be letters, digits and `._+-` (the name also `~@`).
- **Commit statuses** take a commit SHA, not a branch: GitLab wants one.
  GitLab also refuses some moves between states, such as `success` back to
  `pending` (HTTP 400).
- **Issue numbers on GitHub and Forgejo** are shared with pull requests:
  `issue` of a pull request's number answers with `isChangeRequest` set,
  and the label verbs work on pull requests too. On GitLab they are
  separate.

## Errors

Every failure is a `CodehostError`:

| Field | Meaning |
|---|---|
| `kind` | `"codehost"` (`ERROR_KIND`) |
| `message` | what failed, starting with who reported it: the backend deck's own message (`github: GET /repos/me/app: HTTP 404: Not Found`) or `codehost: ` for a check of this deck's |
| `status` | the HTTP status the forge answered: 404 for something that is not there or not visible, 401 / 403 for the token, 409 / 422 for a conflict; 0 for a local check |
| `backend` | `github`, `gitlab` or `forgejo` |

The generic kinds pass through untouched, as the backend threw them:
`"limit"` (a list past the backend's page cap, a download over
`maxBytes`), `"timeout"`, `"closed"`, `"cancelled"` and `"net"`. A `"net"`
error is the `net.NetError` the transport threw for a refused, reset or
unreachable connection, a name that does not resolve or a failed TLS
handshake, with `op`, `reason`, `sent` and `replied` to read. Match the kind first, then read
the fields; never match the message:

```jennifer
try {
    def r as codehost.Release init codehost.release($f, "me/app", "9.9.9");
} catch (e) {
    if ($e.kind == codehost.ERROR_KIND and $e.status == 404) {
        io.printf("no such release on %s\n", $e.backend);
    } elseif ($e.kind == "timeout") {
        io.printf("the forge is slow\n");
    } else {
        throw $e;
    }
}
```

A helper that receives the caught error is typed `codehost.CodehostError`,
not `Error`. On interpreters before the thrown-struct fix (`14fad43`) a
struct caught from another module loses its module identity; read the
fields as above instead of declaring the type.

## Beyond the common verbs

The backend client is in the `Forge`, so anything this deck leaves out is
one call away, with the same token and settings:

```jennifer
match ($f.backend) {
    when "github" {
        github.dispatchWorkflow($f.github, "me/app", "release.yml", "main", {});
    }
    when "gitlab" {
        gitlab.runPipeline($f.gitlab, "me/app", "main", {});
    }
    when "forgejo" {
        forgejo.dispatchWorkflow($f.forgejo, "me/app", "release.yml", "main", {});
    }
}
```

Not covered here, and where it is: reviews and approvals, milestones,
assignees, webhooks, collaborators and members, forks, repository creation
and settings, commits and combined statuses, check runs, CI (Actions,
pipelines, variables, secrets), search, GraphQL, and any raw endpoint
(`call`, `getAll`) - all in the backend decks.

## Trademarks

GitHub™ is a trademark of GitHub, Inc. GitLab™ is a trademark of GitLab Inc.
Codeberg™ is a trademark of Codeberg e.V. Other product and company names,
such as Forgejo™ and Gitea™, may be trademarks of their respective owners.
They are used only to identify the products this deck works with. This deck
is an independent project, not affiliated with, sponsored or endorsed by
GitHub, Inc., GitLab Inc., Codeberg e.V., the Forgejo project or CommitGo,
Inc.
