# @deckyard/codehost

[![test](https://github.com/deckyard/deck-codehost/actions/workflows/test.yml/badge.svg)](https://github.com/deckyard/deck-codehost/actions/workflows/test.yml)
[![Documentation](https://img.shields.io/badge/docs-github%20pages-blue)](https://deckyard.github.io/deck-codehost/)
[![release](https://img.shields.io/github/v/release/deckyard/deck-codehost)](https://github.com/deckyard/deck-codehost/releases/latest)

One API over GitHub, GitLab and Forgejo (and Gitea) for
[Jennifer](https://jennifer-lang.dev/) programs, so a release script or a
triage bot runs against any of them: repositories, issues, labels and
comments, change requests (pull and merge requests), releases and their
assets, branches, tags, files and commit statuses. It is a facade over
[`@deckyard/github`](https://github.com/deckyard/deck-github),
[`@deckyard/gitlab`](https://github.com/deckyard/deck-gitlab) and
[`@deckyard/forgejo`](https://github.com/deckyard/deck-forgejo): states,
drafts, commit-status states, release assets and labels are normalised, and
the backend client stays at hand for whatever only one forge has.

**[Documentation](https://deckyard.github.io/deck-codehost/)**

## Install

```sh
jvc add @deckyard/codehost
```

This vendors the deck to `vendor/deckyard/codehost/`, and its three backend
decks beside it. Without `jvc`, unpack the `src/` subtree of each release
archive (`deckyard-<deck>-<version>.tar.gz`) to `vendor/deckyard/<deck>/`.

## Usage

```jennifer
import "@deckyard/codehost/" as codehost;

def forges as list of codehost.Forge init [
    codehost.connect("github", "github.com", ""),
    codehost.connect("gitlab", "gitlab.com", ""),
    codehost.connect("forgejo", "codeberg.org", "")
];
def repos as list of string init ["BurntSushi/ripgrep", "gitlab-org/cli", "forgejo/forgejo"];
for (def i in 0..3) {
    def r as codehost.Release init codehost.latestRelease($forges[$i], $repos[$i]);
    io.printf("%s %s: %s\n", $forges[$i].backend, $repos[$i], $r.tag);
}
```

`connect(backend, host, token)` takes the backend by name, so it can come
from a configuration file, and a token (`""` for anonymous access). For a
CA certificate, timeouts, retries or plain http, build the client with the
backend deck (`github.client(...)` and its `with*` options) and wrap it
with `fromGithub`, `fromGitlab` or `fromForgejo`.

Errors are one `CodehostError` (kind `"codehost"`, with the HTTP `status`
and the `backend`); `"limit"`, `"timeout"`, `"closed"` and `"cancelled"`
pass through.

## Requirements

Jennifer 0.26.0 or newer, with the `net` capability (it talks HTTPS to the
forges); not usable on `jennifer-tiny`. Depends on `@deckyard/github`,
`@deckyard/gitlab` (`>=0.1.0`) and `@deckyard/forgejo` (`>=0.2.1`); run
`tools/vendor-deps.sh` once before the gate.

## Development

```sh
tools/check-all.sh                   # the full gate, as CI runs it
jennifer test src/codehost_test.j      # the test overlay
tools/check-docs.sh                  # docs against the code
tools/pack.sh dist                   # build the release archive
```

## Licence

LGPL-3.0-only, see [LICENSE](LICENSE). Copyright (C) 2026 mplx &lt;mplx@jennifer-lang.dev&gt;.

`tools/check-headers.sh` checks every source file's SPDX header against
`deck.toml`.
