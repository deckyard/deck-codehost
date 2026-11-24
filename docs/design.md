<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Design

## Scope

One API over the code forges, so a release script or a triage bot runs
against GitHub™, GitLab™ and Forgejo™ (and Gitea™) alike: repositories, issues,
labels and comments, change requests (pull and merge requests), releases and
assets, branches, tags, files and commit statuses.

The deck is a facade over three backend decks, `@deckyard/github`,
`@deckyard/gitlab` and `@deckyard/forgejo`, which do the talking. It covers the
common denominator only, as a storage facade would over storage services.
What one forge alone has stays in the backend decks: GitHub Actions and
secrets, GitLab pipelines, groups and approvals, reviews, milestones,
webhooks, members, forks, search and GraphQL™. Those are reached through the
backend client the `Forge` holds (see the introduction, "Beyond the common
verbs"), so leaving them out costs a program one `match`, not a second
client.

## Decisions

- **A facade over decks, not a fourth client.** Each backend deck already
  handles its forge's authentication, paging, redirects, caps and error
  struct. Repeating that here would double the code that has to track three
  APIs; the facade only routes and normalises.
- **`Forge` holds the backend's own client.** `Forge` carries the backend
  name and that backend's typed client in a field of its type. Every verb
  switches on the name. A zero `Forge` makes every verb throw "no backend".
- **`connect(backend, host, token)` builds the client inside the deck**, so
  a program imports only codehost (jvc installs the backends transitively)
  and can take the backend from a configuration file. `fromGithub`,
  `fromGitlab` and `fromForgejo` wrap a client built with settings `connect`
  does not take: a CA certificate, timeouts, retries, plain http.
- **Addressing.** `repo` is `owner/name`, or GitLab's full path with
  subgroups; `number` is the issue or change request number (GitLab's
  `iid`). A number below 1 is refused locally on every forge.
- **One normalised shape per thing**, with the forge's original kept where it
  carries information:
  - States: issues `open` / `closed`; change requests `open` / `closed` /
    `merged` (GitLab `opened` and `locked` are `open`). Asking for `merged` or
    `closed` on GitHub and Forgejo lists `closed` and filters.
  - Commit statuses map to `STATUS_STATES` both ways (GitLab `running` and
    friends are `pending`, `failed` is `failure`, `canceled` is `error`;
    Forgejo `warning` is `success`, as a finished and not failed run).
    `forgeState` keeps the forge's own word.
  - `mergeSha` only once merged. GitHub's test merge commit for an open pull
    request is dropped; GitLab gives the merge commit, else the squash
    commit, else the head (fast-forward).
  - `mergeable` is the forge's flag and open and not a draft: GitHub reports
    true for drafts and closed pulls, Forgejo for merged ones.
  - Label colours are lower case; GitLab keeps the case it was given.
  - Directory entries are `file`, `dir`, `symlink` or `submodule`. GitHub's
    contents listing calls symlinks and submodules files, so the deck reads
    the directory's git tree instead, through documented calls only (two
    requests; the one-request `<ref>:<path>` form is undocumented and was
    rejected).
- **Drafts follow each forge's own title prefixes.** GitHub has a draft flag.
  GitLab reads `Draft:`, `[Draft]` and `(Draft)` (no longer `WIP:`);
  Forgejo and Gitea read `WIP:` and `[WIP]` by default, and `Draft:` is not
  a draft there. The deck adds the forge's prefix unless the title already
  has one, and `createChangeRequest` with `isDraft` false refuses a title the
  forge would read as a draft. Another forge's prefix passes as text.
- **Labels by name.** Forgejo silently drops a name it has no repository or
  organisation label for, so the deck sets the labels first, then creates
  the dropped ones in `LABEL_COLOR` and adds them. Listing repository labels
  first, as an earlier version did, duplicated organisation labels.
- **Merging.** Styles `merge`, `squash` and `rebase`; GitLab's `rebase` is
  refused because its merge method is a project setting. The head branch is
  deleted only when it lives in the same repository, on every forge.
- **Releases.** GitLab releases have no id (0) and no pre-releases (refused).
  An empty target is looked up as the default branch on GitLab. GitLab
  assets go to the generic package registry with a release link; Forgejo
  draft releases have `published` "".
- **Raw calls only where a deck lacks a verb.** The one left is GitHub's git
  tree read above. Gaps found in the backend decks were fixed there and the
  `[decks]` floors raised, rather than worked around here.

## Errors

Every failure is one struct, `CodehostError{kind, message, status,
backend}`, kind `"codehost"` (`ERROR_KIND`). It is rebuilt from the backend
deck's own struct (`GithubError`, `GitlabError`, `ForgejoError`): the message
stays as the backend wrote it, `status` is the HTTP status (0 for a local
check), `backend` names the forge. A failure of another kind inside a backend
gets the backend and that kind in front of its message. The deck's own checks
start `codehost: `.

The generic kinds `"limit"`, `"timeout"`, `"closed"`, `"cancelled"` and
`"net"` pass through untouched, as the backend threw them. A `"net"` error is
the `net.NetError` of a refused, reset or unreachable connection, with its
`op`, `reason`, `sent` and `replied`; the backend floors are the first
releases that pass it on themselves. The deck does not retry.

The catch block is the same in every verb and stays inline: a caught value
cannot be handed to a helper typed `Error` when it is a struct, and a user
function cannot take `any`. It reads `status` inside its own `try`, so a
plain `Error` without the field reads as 0. The deck never declares a caught
value as a backend struct type, so it works on interpreters where a thrown
struct loses its module identity.

## Security and limits

- Tokens go only where the backend decks send them: an asset download is
  allowed only from the forge's own address, with the token; links to other
  hosts are refused.
- Plain http to another machine is refused by the github and forgejo
  backends unless their client allows it; `connect` does not, so such a
  setup goes through `fromGithub` or `fromForgejo` with the option.
- `readFile` and `downloadAsset` take `maxBytes` (0 for 64 MiB, negative for
  no limit). It is passed to the github and gitlab decks; the forgejo deck
  reads at most 64 MiB whatever the cap, so the deck checks the length after
  that read. Over the cap is kind `"limit"`.
- Page caps, timeouts and retries are the backend decks'.
- Empty label names are refused before anything is sent.

## Testing and validation

- The suite is a conformance test: every verb runs against a loopback fake
  of each backend, given that backend's canned JSON, and must produce the
  same normalised value from all three, with the expected request lines.
  The GitHub fake uses Enterprise paths, since it is not github.com.
- Errors: 404 mapping per backend, local checks, the generic kinds
  (`"limit"` from a download over `maxBytes`, `"timeout"` from a delayed
  reply, `"cancelled"` from a cancelled call, `"net"` from a closed port on
  every backend) passing through.
- The overlays pass from a bare copy of `src/` plus `vendor/`.
- Live, 2026-11-14: anonymous reads against github.com, gitlab.com and
  codeberg.org; every write verb against Forgejo 13.0.5 and Gitea 1.24.7 in
  throwaway containers and against GitLab CE 19.5.5 in a local container
  (tokens revoked, scratch projects deleted afterwards).
- Not covered by the fake: the `"closed"` kind, and a GitHub merge from a
  fork (the github deck's own logic).

## Known limitations and open questions

- A Forgejo lightweight tag reports the commit message as its message.
- gitlab.com omits a repository's open issue count to anonymous callers and
  answers 401 to anonymous notes and labels.
- GitLab deletes a merged source branch in the background, so a branch
  listing right after a merge may still show it.
- `uploadAsset` exposes no content type; assets go up as
  `application/octet-stream`.
- An instance that configures other draft prefixes is read with a broad
  pattern on Forgejo, but only the default prefixes are added.

## Dependencies on the interpreter

Floor `>=0.27.0` (the UTF-8 codecs of `encoding.encode` / `decode`),
capability `net`. `[decks]`: `@deckyard/github`
`>=0.3.0`, `@deckyard/gitlab` `>=0.4.0`, `@deckyard/forgejo` `>=0.4.0`. The
backends are vendored from their released tags, so unreleased backend
changes are invisible here until released. From `jennifer`'s milestones:
M28.57 (the decks follow the error conventions), M28.65 (transport failures
as `net.NetError`, kind `"net"`, passed on) and M28.56 (a caught struct keeps
its module identity), which the inline catch avoids depending on.
