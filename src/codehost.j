# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * One API over GitHub, GitLab and Forgejo (and Gitea): repositories, issues,
 * change requests (pull and merge requests), releases and their assets,
 * branches, tags, files and commit statuses.
 *
 * A `Forge` wraps the client of one backend deck, built with that deck's own
 * constructor and options (`github.withToken`, `gitlab.withCaCert`, ...),
 * and every verb runs on whichever backend it holds. Only what all three
 * forges have is here; the backend client stays in its field of the `Forge`
 * (`$f.github`, `$f.gitlab`, `$f.forgejo`) for everything else.
 *
 * States, commit-status states, release assets, draft flags and labels are
 * normalised (see the docs). Every failure is a `CodehostError` (kind
 * `"codehost"`) naming the backend and the HTTP status, except the generic
 * kinds `"limit"`, `"timeout"`, `"closed"` and `"cancelled"`, which pass
 * through untouched.
 *
 * @module codehost
 * @example
 *   def f as codehost.Forge init codehost.connect("github", "github.com", $token);
 *   for (def i in codehost.issues($f, "BurntSushi/ripgrep", "open")) {
 *       io.printf("#%d %s\n", $i.number, $i.title);
 *   }
 */
use convert;
use json;
use lists;
use regex;
use strings;
import "@deckyard/github/" as github;
import "@deckyard/gitlab/" as gitlab;
import "@deckyard/forgejo/" as forgejo;
import "uri.j" as uri;

/** The `kind` of every error the deck throws. */
export def const ERROR_KIND as string init "codehost";

/** The backends a `Forge` can hold; Gitea goes through `forgejo`. */
export def const BACKENDS as list of string init ["github", "gitlab", "forgejo"];

/** The ways `mergeChangeRequest` can merge; GitLab takes `merge` and `squash`. */
export def const MERGE_STYLES as list of string init ["merge", "squash", "rebase"];

/** The normalised commit-status states, which `setCommitStatus` takes. */
export def const STATUS_STATES as list of string init ["pending", "success", "failure", "error"];

/** The colour of a label `setIssueLabels` / `addIssueLabels` create on Forgejo. */
export def const LABEL_COLOR as string init "#ededed";

# The kinds that pass through every verb as they are.
def const GENERIC_KINDS as list of string init ["limit", "timeout", "closed", "cancelled"];

# The title prefixes GitLab reads as "draft" (its `DRAFT_REGEX`; `WIP:` no
# longer counts).
def const GITLAB_DRAFT as string init '^(?i)(\[draft\]|\(draft\)|draft:)+\s*';

# The title prefixes Forgejo and Gitea read as "draft" by default
# (`WORK_IN_PROGRESS_PREFIXES`); `Draft:` does not count there.
def const FORGEJO_DRAFT as string init '^(?i)(wip:|\[wip\])\s*';

# Any draft prefix, taken off the title of a pull request Forgejo reports as
# a draft: an instance may configure prefixes of its own.
def const DRAFT_PREFIX as string init '^(?i)\s*(\[(draft|wip)\]|\((draft|wip)\)|(draft|wip)\s*:)\s*';

# An owner or repository name as GitHub and Forgejo allow it.
def const NAME_PATTERN as string init '^[A-Za-z0-9_.-]+$';

/**
 * A code forge: the backend's name and its client. Build it with
 * `fromGithub`, `fromGitlab` or `fromForgejo`; only the field of its
 * backend is set.
 *
 * @field backend {string} `github`, `gitlab` or `forgejo`
 * @field github {github.Client} the GitHub client, for anything this deck
 *   does not cover
 * @field gitlab {gitlab.Client} the GitLab client
 * @field forgejo {forgejo.Client} the Forgejo (or Gitea) client
 */
export def struct Forge {
    backend as string,
    github as github.Client,
    gitlab as gitlab.Client,
    forgejo as forgejo.Client
};

/**
 * A failed request or a refused value. Every error of kind `"codehost"` is
 * one, so its fields are safe to read once the kind matches.
 *
 * @field kind {string} always `"codehost"` (`ERROR_KIND`)
 * @field message {string} what failed, starting with who reported it:
 *   `github: `, `gitlab: `, `forgejo: ` or `codehost: `
 * @field status {int} the HTTP status the forge answered (401, 403, 404,
 *   409, 422, ...); 0 when no answer was read and for a local check
 * @field backend {string} the backend of the `Forge`; "" for a `Forge`
 *   built without a constructor
 */
export def struct CodehostError {
    kind as string,
    message as string,
    status as int,
    backend as string
};

/**
 * A repository (a GitLab project).
 *
 * @field fullName {string} `owner/name`; GitLab's full path, subgroups
 *   included
 * @field owner {string} the user, organization or (GitLab) group path
 * @field name {string} the last segment of the path
 * @field description {string} the description
 * @field isPrivate {bool} whether it is not public (GitLab's `internal`
 *   counts as private)
 * @field isFork {bool} whether it is a fork
 * @field isArchived {bool} whether it is archived
 * @field defaultBranch {string} e.g. `main`
 * @field htmlUrl {string} its page
 * @field cloneUrl {string} the HTTPS clone URL
 * @field sshUrl {string} the SSH clone URL
 * @field stars {int} the star count
 * @field openIssues {int} open issues; on GitHub pull requests included
 * @field updated {string} last update or activity, RFC 3339
 */
export def struct Repository {
    fullName as string,
    owner as string,
    name as string,
    description as string,
    isPrivate as bool,
    isFork as bool,
    isArchived as bool,
    defaultBranch as string,
    htmlUrl as string,
    cloneUrl as string,
    sshUrl as string,
    stars as int,
    openIssues as int,
    updated as string
};

/**
 * An issue.
 *
 * @field number {int} the number within the repository (GitLab's `iid`)
 * @field title {string} the title
 * @field body {string} the text, Markdown
 * @field state {string} `open` or `closed`
 * @field author {string} who opened it
 * @field labels {list of string} label names
 * @field assignees {list of string} assigned user names
 * @field comments {int} the comment count, without GitLab's system notes
 * @field isChangeRequest {bool} whether the number is a pull request's
 *   (GitHub and Forgejo number both alike)
 * @field created {string} RFC 3339
 * @field updated {string} RFC 3339
 * @field closed {string} RFC 3339; "" while open
 * @field htmlUrl {string} its page
 */
export def struct Issue {
    number as int,
    title as string,
    body as string,
    state as string,
    author as string,
    labels as list of string,
    assignees as list of string,
    comments as int,
    isChangeRequest as bool,
    created as string,
    updated as string,
    closed as string,
    htmlUrl as string
};

/**
 * A comment on an issue or change request (a GitLab note).
 *
 * @field id {int} the comment id
 * @field author {string} who wrote it
 * @field body {string} the text, Markdown
 * @field created {string} RFC 3339
 */
export def struct Comment {
    id as int,
    author as string,
    body as string,
    created as string
};

/**
 * A label of a repository.
 *
 * @field name {string} the name
 * @field color {string} the colour, `#rrggbb`
 * @field description {string} the description
 */
export def struct Label {
    name as string,
    color as string,
    description as string
};

/**
 * A change request: a GitHub or Forgejo pull request, a GitLab merge
 * request.
 *
 * @field number {int} the number within the repository (GitLab's `iid`)
 * @field title {string} the title, without the draft prefix GitLab and
 *   Forgejo keep in it
 * @field body {string} the text, Markdown
 * @field state {string} `open`, `closed` (without merging) or `merged`
 * @field author {string} who opened it
 * @field head {string} the branch with the changes
 * @field base {string} the branch it merges into
 * @field headSha {string} the commit at the head
 * @field isDraft {bool} whether it is a draft
 * @field mergeable {bool} whether the forge would merge it now; false
 *   unless it is open and not a draft, while the forge is still computing
 *   that, and in a GitHub listing
 * @field mergeSha {string} the commit the merge left on the base branch;
 *   "" until merged
 * @field htmlUrl {string} its page
 */
export def struct ChangeRequest {
    number as int,
    title as string,
    body as string,
    state as string,
    author as string,
    head as string,
    base as string,
    headSha as string,
    isDraft as bool,
    mergeable as bool,
    mergeSha as string,
    htmlUrl as string
};

/**
 * A file attached to a release. On GitLab it is a release link.
 *
 * @field id {int} the asset id (GitLab: the link id)
 * @field name {string} the file name
 * @field contentType {string} the media type; "" where the forge does not
 *   report it (GitLab, Forgejo)
 * @field size {int} bytes; 0 on GitLab, which does not report it
 * @field downloads {int} the download count; 0 on GitLab
 * @field downloadUrl {string} the link a browser follows
 * @field apiUrl {string} the URL `downloadAsset` reads
 */
export def struct Asset {
    id as int,
    name as string,
    contentType as string,
    size as int,
    downloads as int,
    downloadUrl as string,
    apiUrl as string
};

/**
 * A release.
 *
 * @field id {int} the release id; 0 on GitLab, where the tag is the key
 * @field tag {string} the tag it is for
 * @field name {string} the title
 * @field body {string} the notes, Markdown
 * @field isDraft {bool} whether it is a draft; always false on GitLab
 * @field isPrerelease {bool} whether it is a pre-release; always false on
 *   GitLab
 * @field created {string} RFC 3339
 * @field published {string} RFC 3339 (GitLab's release date); "" for a
 *   draft
 * @field htmlUrl {string} its page
 * @field assets {list of Asset} the attached files
 */
export def struct Release {
    id as int,
    tag as string,
    name as string,
    body as string,
    isDraft as bool,
    isPrerelease as bool,
    created as string,
    published as string,
    htmlUrl as string,
    assets as list of Asset
};

/**
 * A branch.
 *
 * @field name {string} the name
 * @field sha {string} the commit it points at
 * @field isProtected {bool} whether a protection rule covers it
 */
export def struct Branch {
    name as string,
    sha as string,
    isProtected as bool
};

/**
 * A tag.
 *
 * @field name {string} the name
 * @field sha {string} the commit it points at
 * @field message {string} the annotation; "" for a lightweight tag, and in
 *   a GitHub listing, which does not carry it; on Forgejo and Gitea a
 *   lightweight tag's is its commit's message
 */
export def struct Tag {
    name as string,
    sha as string,
    message as string
};

/**
 * An entry of a directory in a repository.
 *
 * @field name {string} the name
 * @field path {string} the path from the repository root
 * @field type {string} `file`, `dir`, `symlink` or `submodule`
 * @field size {int} bytes; 0 for a directory, and on GitLab
 * @field sha {string} the blob or tree SHA
 */
export def struct Entry {
    name as string,
    path as string,
    type as string,
    size as int,
    sha as string
};

/**
 * A status a CI system set on a commit.
 *
 * @field context {string} which check it is, e.g. `ci/build` (GitLab's
 *   `name`)
 * @field state {string} one of `STATUS_STATES`
 * @field forgeState {string} the state as the forge reported it, e.g.
 *   GitLab's `running` or Forgejo's `warning`
 * @field description {string} a short text
 * @field targetUrl {string} where the details are
 * @field creator {string} who set it
 * @field created {string} RFC 3339
 */
export def struct CommitStatus {
    context as string,
    state as string,
    forgeState as string,
    description as string,
    targetUrl as string,
    creator as string,
    created as string
};

# --- errors -----------------------------------------------------------------

# fail throws the CodehostError of a check of the deck's own.
func fail(f as Forge, message as string) {
    throw CodehostError{
        kind: ERROR_KIND,
        message: "codehost: " + $message,
        status: 0,
        backend: $f.backend
    };
}

# passes says whether a caught error goes on as it is: a generic kind, or a
# CodehostError already.
func passes(kind as string) {
    return $kind == ERROR_KIND or lists.contains(GENERIC_KINDS, $kind);
}

# failFrom throws the CodehostError a backend's failure becomes. The message
# stays as the backend wrote it (`github: ...`); a failure of another kind
# (an interpreter error inside the backend) is prefixed with the backend and
# its kind.
func failFrom(f as Forge, kind as string, message as string, status as int) {
    def text as string init $message;
    if ($kind != $f.backend) {
        $text = $f.backend + ": " + $kind + ": " + $message;
    }
    throw CodehostError{kind: ERROR_KIND, message: $text, status: $status, backend: $f.backend};
}

# noBackend throws for a Forge no constructor built.
func noBackend(f as Forge) {
    fail(
        $f,
        "no backend " + shown($f.backend) + "; build the Forge with fromGithub, " +
            "fromGitlab or fromForgejo");
}

# shown quotes a caller's string for a message: cut to 60 characters,
# anything but printable ASCII as `?`.
func shown(text as string) {
    def cut as string init $text;
    def more as string init "";
    if (len($text) > 60) {
        $cut = strings.substring($text, 0, 60);
        $more = "...";
    }
    return "\"" + regex.replace("[^ -~]", $cut, "?") + $more + "\"";
}

# checkNumber refuses an issue or change request number below 1 on every
# forge, as the gitlab deck does, instead of asking GitHub or Forgejo for it.
func checkNumber(f as Forge, number as int) {
    if ($number < 1) {
        fail($f, "a number is 1 or more, got " + convert.toString($number));
    }
}

# --- constructors -----------------------------------------------------------

/**
 * A forge on GitHub (github.com or an Enterprise Server).
 *
 * @param c {github.Client} the client, from `github.client` and its
 *   `with*` options
 * @return {Forge} the forge
 * @example
 *   def f as codehost.Forge init codehost.fromGithub(github.withToken(github.client("github.com"), $token));
 */
export func fromGithub(c as github.Client) {
    def f as Forge;
    $f.backend = "github";
    $f.github = $c;
    return $f;
}

/**
 * A forge on GitLab (gitlab.com or a self-managed instance).
 *
 * @param c {gitlab.Client} the client, from `gitlab.client` and its
 *   `with*` options
 * @return {Forge} the forge
 * @example
 *   def f as codehost.Forge init codehost.fromGitlab(gitlab.withToken(gitlab.client("gitlab.com"), $token));
 */
export func fromGitlab(c as gitlab.Client) {
    def f as Forge;
    $f.backend = "gitlab";
    $f.gitlab = $c;
    return $f;
}

/**
 * A forge on Forgejo (Codeberg or a self-hosted instance) or Gitea.
 *
 * @param c {forgejo.Client} the client, from `forgejo.client` and its
 *   `with*` options
 * @return {Forge} the forge
 * @example
 *   def f as codehost.Forge init codehost.fromForgejo(forgejo.client("codeberg.org"));
 */
export func fromForgejo(c as forgejo.Client) {
    def f as Forge;
    $f.backend = "forgejo";
    $f.forgejo = $c;
    return $f;
}

/**
 * A forge by name, with the backend's client built here, so a program
 * needs no import of the backend deck. The backend may come from a
 * configuration file. For a CA certificate, timeouts, retries or plain
 * http, build the client with the backend deck and use `fromGithub`,
 * `fromGitlab` or `fromForgejo`.
 *
 * @param backend {string} one of `BACKENDS`: `github`, `gitlab` or
 *   `forgejo` (also for Gitea)
 * @param host {string} the forge's host or base URL, as the backend
 *   deck's `client` takes it: `github.com`, `gitlab.example.org`,
 *   `https://codeberg.org`
 * @param token {string} an access token; "" for anonymous access
 * @return {Forge} the forge
 * @throws {CodehostError} kind `"codehost"` for an unknown backend, or a
 *   host or token the backend deck refuses
 * @example
 *   def f as codehost.Forge init codehost.connect("gitlab", "gitlab.com", $token);
 */
export func connect(backend as string, host as string, token as string) {
    def f as Forge;
    $f.backend = $backend;
    try {
        match ($backend) {
            when "github" {
                def c as github.Client init github.client($host);
                if ($token != "") {
                    $c = github.withToken($c, $token);
                }
                return fromGithub($c);
            }
            when "gitlab" {
                def c as gitlab.Client init gitlab.client($host);
                if ($token != "") {
                    $c = gitlab.withToken($c, $token);
                }
                return fromGitlab($c);
            }
            when "forgejo" {
                def c as forgejo.Client init forgejo.client($host);
                if ($token != "") {
                    $c = forgejo.withToken($c, $token);
                }
                return fromForgejo($c);
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        failFrom($f, $e.kind, $e.message, 0);
    }
    $f.backend = "";
    fail($f, "a backend is one of " + strings.join(BACKENDS, ", ") + ", got " + shown($backend));
}

# --- repositories -----------------------------------------------------------

# githubRepository normalises a GitHub repository.
func githubRepository(r as github.Repository) {
    return Repository{
        fullName: $r.fullName,
        owner: $r.owner,
        name: $r.name,
        description: $r.description,
        isPrivate: $r.isPrivate,
        isFork: $r.isFork,
        isArchived: $r.isArchived,
        defaultBranch: $r.defaultBranch,
        htmlUrl: $r.htmlUrl,
        cloneUrl: $r.cloneUrl,
        sshUrl: $r.sshUrl,
        stars: $r.stars,
        openIssues: $r.openIssues,
        updated: $r.updated
    };
}

# gitlabRepository normalises a GitLab project.
func gitlabRepository(p as gitlab.Project) {
    return Repository{
        fullName: $p.fullPath,
        owner: $p.namespace,
        name: $p.path,
        description: $p.description,
        isPrivate: $p.visibility != "public",
        isFork: $p.forkedFrom != "",
        isArchived: $p.isArchived,
        defaultBranch: $p.defaultBranch,
        htmlUrl: $p.webUrl,
        cloneUrl: $p.httpUrl,
        sshUrl: $p.sshUrl,
        stars: $p.stars,
        openIssues: $p.openIssues,
        updated: $p.lastActivity
    };
}

# forgejoRepository normalises a Forgejo repository.
func forgejoRepository(r as forgejo.Repository) {
    return Repository{
        fullName: $r.fullName,
        owner: $r.owner,
        name: $r.name,
        description: $r.description,
        isPrivate: $r.isPrivate,
        isFork: $r.isFork,
        isArchived: $r.isArchived,
        defaultBranch: $r.defaultBranch,
        htmlUrl: $r.htmlUrl,
        cloneUrl: $r.cloneUrl,
        sshUrl: $r.sshUrl,
        stars: $r.stars,
        openIssues: $r.openIssues,
        updated: $r.updated
    };
}

/**
 * One repository.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path with subgroups
 * @return {Repository} the repository
 * @throws {CodehostError} kind `"codehost"` when it does not exist or the
 *   token may not see it (HTTP 404)
 */
export func repository(f as Forge, repo as string) {
    try {
        match ($f.backend) {
            when "github" { return githubRepository(github.repository($f.github, $repo)); }
            when "gitlab" { return gitlabRepository(gitlab.project($f.gitlab, $repo)); }
            when "forgejo" { return forgejoRepository(forgejo.repository($f.forgejo, $repo)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * The repositories the token may reach: its own and those of its
 * organizations, groups and collaborations.
 *
 * @param f {Forge} the forge
 * @return {list of Repository} the repositories
 * @throws {CodehostError} kind `"codehost"` without a token (HTTP 401)
 */
export func myRepositories(f as Forge) {
    def out as list of Repository init [];
    try {
        match ($f.backend) {
            when "github" {
                for (def r in github.myRepositories($f.github)) {
                    $out[] = githubRepository($r);
                }
                return $out;
            }
            when "gitlab" {
                for (def p in gitlab.myProjects($f.gitlab)) {
                    $out[] = gitlabRepository($p);
                }
                return $out;
            }
            when "forgejo" {
                for (def r in forgejo.myRepositories($f.forgejo)) {
                    $out[] = forgejoRepository($r);
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- issues -----------------------------------------------------------------

# openState maps GitLab's `opened` and `locked` to `open`.
func openState(state as string) {
    if ($state == "opened" or $state == "locked") {
        return "open";
    }
    return $state;
}

# githubIssue normalises a GitHub issue.
func githubIssue(i as github.Issue) {
    return Issue{
        number: $i.number,
        title: $i.title,
        body: $i.body,
        state: $i.state,
        author: $i.author,
        labels: $i.labels,
        assignees: $i.assignees,
        comments: $i.comments,
        isChangeRequest: $i.isPull,
        created: $i.created,
        updated: $i.updated,
        closed: $i.closed,
        htmlUrl: $i.htmlUrl
    };
}

# gitlabIssue normalises a GitLab issue.
func gitlabIssue(i as gitlab.Issue) {
    return Issue{
        number: $i.iid,
        title: $i.title,
        body: $i.description,
        state: openState($i.state),
        author: $i.author,
        labels: $i.labels,
        assignees: $i.assignees,
        comments: $i.notes,
        isChangeRequest: false,
        created: $i.created,
        updated: $i.updated,
        closed: $i.closed,
        htmlUrl: $i.webUrl
    };
}

# forgejoIssue normalises a Forgejo issue.
func forgejoIssue(i as forgejo.Issue) {
    return Issue{
        number: $i.number,
        title: $i.title,
        body: $i.body,
        state: $i.state,
        author: $i.author,
        labels: $i.labels,
        assignees: $i.assignees,
        comments: $i.comments,
        isChangeRequest: $i.isPull,
        created: $i.created,
        updated: $i.updated,
        closed: $i.closed,
        htmlUrl: $i.htmlUrl
    };
}

# issueFilter checks an issue state filter and spells it for the backend.
func issueFilter(f as Forge, state as string) {
    if (not lists.contains(["open", "closed", "all"], $state)) {
        fail($f, "an issue state is open, closed or all, got " + shown($state));
    }
    if ($f.backend == "gitlab" and $state == "open") {
        return "opened";
    }
    return $state;
}

/**
 * The issues of a repository, newest first, without change requests.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param state {string} `open`, `closed` or `all`
 * @return {list of Issue} the issues
 * @throws {CodehostError} kind `"codehost"` on another state, or when the
 *   repository has issues turned off
 * @throws {Error} kind `"limit"` past the backend's page cap
 */
export func issues(f as Forge, repo as string, state as string) {
    def out as list of Issue init [];
    try {
        def filter as string init issueFilter($f, $state);
        match ($f.backend) {
            when "github" {
                for (def i in github.issues($f.github, $repo, $filter)) {
                    $out[] = githubIssue($i);
                }
                return $out;
            }
            when "gitlab" {
                for (def i in gitlab.issues($f.gitlab, $repo, $filter)) {
                    $out[] = gitlabIssue($i);
                }
                return $out;
            }
            when "forgejo" {
                for (def i in forgejo.issues($f.forgejo, $repo, $filter)) {
                    $out[] = forgejoIssue($i);
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * One issue. On GitHub and Forgejo the number may be a pull request's,
 * which comes as an issue with `isChangeRequest` set.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number (GitLab's `iid`)
 * @return {Issue} the issue
 * @throws {CodehostError} kind `"codehost"` when it does not exist (HTTP 404)
 */
export func issue(f as Forge, repo as string, number as int) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" { return githubIssue(github.issue($f.github, $repo, $number)); }
            when "gitlab" { return gitlabIssue(gitlab.issue($f.gitlab, $repo, $number)); }
            when "forgejo" { return forgejoIssue(forgejo.issue($f.forgejo, $repo, $number)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Open an issue.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param title {string} the title
 * @param body {string} the text, Markdown; "" for none
 * @return {Issue} the new issue
 * @throws {CodehostError} kind `"codehost"` on an empty title
 */
export func createIssue(f as Forge, repo as string, title as string, body as string) {
    try {
        match ($f.backend) {
            when "github" { return githubIssue(github.createIssue($f.github, $repo, $title, $body)); }
            when "gitlab" { return gitlabIssue(gitlab.createIssue($f.gitlab, $repo, $title, $body)); }
            when "forgejo" {
                return forgejoIssue(forgejo.createIssue($f.forgejo, $repo, $title, $body));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Close an issue.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @return {Issue} the closed issue
 * @throws {CodehostError} kind `"codehost"` when it does not exist (HTTP 404)
 */
export func closeIssue(f as Forge, repo as string, number as int) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" { return githubIssue(github.closeIssue($f.github, $repo, $number)); }
            when "gitlab" { return gitlabIssue(gitlab.closeIssue($f.gitlab, $repo, $number)); }
            when "forgejo" { return forgejoIssue(forgejo.closeIssue($f.forgejo, $repo, $number)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Reopen a closed issue.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @return {Issue} the reopened issue
 * @throws {CodehostError} kind `"codehost"` when it does not exist (HTTP 404)
 */
export func reopenIssue(f as Forge, repo as string, number as int) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" { return githubIssue(github.reopenIssue($f.github, $repo, $number)); }
            when "gitlab" { return gitlabIssue(gitlab.reopenIssue($f.gitlab, $repo, $number)); }
            when "forgejo" { return forgejoIssue(forgejo.reopenIssue($f.forgejo, $repo, $number)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- comments ---------------------------------------------------------------

# githubComment normalises a GitHub comment.
func githubComment(c as github.Comment) {
    return Comment{id: $c.id, author: $c.author, body: $c.body, created: $c.created};
}

# gitlabComment normalises a GitLab note.
func gitlabComment(n as gitlab.Note) {
    return Comment{id: $n.id, author: $n.author, body: $n.body, created: $n.created};
}

# forgejoComment normalises a Forgejo comment.
func forgejoComment(c as forgejo.Comment) {
    return Comment{id: $c.id, author: $c.author, body: $c.body, created: $c.created};
}

# gitlabComments normalises GitLab notes, leaving out the system notes
# GitLab writes for events (label changes, pushes), which GitHub and Forgejo
# do not list as comments.
func gitlabComments(notes as list of gitlab.Note) {
    def out as list of Comment init [];
    for (def n in $notes) {
        if (not $n.isSystem) {
            $out[] = gitlabComment($n);
        }
    }
    return $out;
}

/**
 * The comments on an issue, oldest first. GitLab's system notes are left
 * out.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @return {list of Comment} the comments
 * @throws {CodehostError} kind `"codehost"` when the issue does not exist
 */
export func comments(f as Forge, repo as string, number as int) {
    def out as list of Comment init [];
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" {
                for (def c in github.comments($f.github, $repo, $number)) {
                    $out[] = githubComment($c);
                }
                return $out;
            }
            when "gitlab" { return gitlabComments(gitlab.notes($f.gitlab, $repo, $number)); }
            when "forgejo" {
                for (def c in forgejo.comments($f.forgejo, $repo, $number)) {
                    $out[] = forgejoComment($c);
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Comment on an issue.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @param body {string} the text, Markdown
 * @return {Comment} the new comment
 * @throws {CodehostError} kind `"codehost"` on an empty text
 */
export func comment(f as Forge, repo as string, number as int, body as string) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" { return githubComment(github.comment($f.github, $repo, $number, $body)); }
            when "gitlab" { return gitlabComment(gitlab.addNote($f.gitlab, $repo, $number, $body)); }
            when "forgejo" {
                return forgejoComment(forgejo.comment($f.forgejo, $repo, $number, $body));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- labels -----------------------------------------------------------------

/**
 * The labels of a repository (on GitLab those of its groups included).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @return {list of Label} the labels
 * @throws {CodehostError} kind `"codehost"` when the repository does not
 *   exist
 */
export func labels(f as Forge, repo as string) {
    def out as list of Label init [];
    try {
        match ($f.backend) {
            when "github" {
                for (def l in github.labels($f.github, $repo)) {
                    $out[] = Label{
                        name: $l.name,
                        color: strings.lower($l.color),
                        description: $l.description
                    };
                }
                return $out;
            }
            when "gitlab" {
                for (def l in gitlab.labels($f.gitlab, $repo)) {
                    $out[] = Label{
                        name: $l.name,
                        color: strings.lower($l.color),
                        description: $l.description
                    };
                }
                return $out;
            }
            when "forgejo" {
                for (def l in forgejo.labels($f.forgejo, $repo)) {
                    $out[] = Label{
                        name: $l.name,
                        color: strings.lower($l.color),
                        description: $l.description
                    };
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Create a label.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param name {string} the name
 * @param color {string} the colour, `#rrggbb`
 * @param description {string} the description; "" for none
 * @return {Label} the new label
 * @throws {CodehostError} kind `"codehost"` on an empty name or a colour
 *   that is not `#rrggbb`, or when it exists (GitHub 422, GitLab 409)
 */
export func createLabel(
    f as Forge,
    repo as string,
    name as string,
    color as string,
    description as string) {
    try {
        match ($f.backend) {
            when "github" {
                def l as github.Label init github.createLabel(
                    $f.github,
                    $repo,
                    $name,
                    $color,
                    $description);
                return Label{
                    name: $l.name,
                    color: strings.lower($l.color),
                    description: $l.description
                };
            }
            when "gitlab" {
                def l as gitlab.Label init gitlab.createLabel(
                    $f.gitlab,
                    $repo,
                    $name,
                    $color,
                    $description);
                return Label{
                    name: $l.name,
                    color: strings.lower($l.color),
                    description: $l.description
                };
            }
            when "forgejo" {
                def l as forgejo.Label init forgejo.createLabel(
                    $f.forgejo,
                    $repo,
                    $name,
                    $color,
                    $description);
                return Label{
                    name: $l.name,
                    color: strings.lower($l.color),
                    description: $l.description
                };
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# githubLabelNames are the names of a GitHub label list.
func githubLabelNames(found as list of github.Label) {
    def out as list of string init [];
    for (def l in $found) {
        $out[] = $l.name;
    }
    return $out;
}

# forgejoLabelNames are the names of a Forgejo label list.
func forgejoLabelNames(found as list of forgejo.Label) {
    def out as list of string init [];
    for (def l in $found) {
        $out[] = $l.name;
    }
    return $out;
}

# forgejoCheckNames refuses an empty label name, which Forgejo would drop
# without a word.
func forgejoCheckNames(f as Forge, names as list of string) {
    for (def name in $names) {
        if (strings.trim($name) == "") {
            fail($f, "a label needs a name, got " + shown($name));
        }
    }
}

# forgejoCompleted finishes labelling a Forgejo issue. Forgejo drops a name it
# has no label for, in the repository or its organization: those it lacks
# (`names` missing from `got`, the issue's labels now) that the repository
# has no label of are created, in `LABEL_COLOR`, and added, as GitHub and
# GitLab do on their own. Answers the issue's label names.
func forgejoCompleted(
    f as Forge,
    repo as string,
    number as int,
    names as list of string,
    got as list of string) {
    def missing as list of string init [];
    for (def name in $names) {
        if (not lists.contains($got, $name) and not lists.contains($missing, $name)) {
            $missing[] = $name;
        }
    }
    if (len($missing) == 0) {
        return $got;
    }
    def have as list of string init forgejoLabelNames(forgejo.labels($f.forgejo, $repo));
    def made as list of string init [];
    for (def name in $missing) {
        if (not lists.contains($have, $name)) {
            forgejo.createLabel($f.forgejo, $repo, $name, LABEL_COLOR, "");
            $made[] = $name;
        }
    }
    if (len($made) == 0) {
        return $got;
    }
    return forgejoLabelNames(forgejo.addIssueLabels($f.forgejo, $repo, $number, $made));
}

/**
 * Replace the labels of an issue (on GitHub and Forgejo also of a pull
 * request, by its number). A name that is no label yet creates one, on
 * every forge (on Forgejo the deck creates it, in `LABEL_COLOR`; a label of
 * the repository's organization counts as one).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @param names {list of string} label names; `[]` for none
 * @return {list of string} the issue's label names now
 * @throws {CodehostError} kind `"codehost"` on an empty name, or a name
 *   with a comma on GitLab
 */
export func setIssueLabels(f as Forge, repo as string, number as int, names as list of string) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" {
                return githubLabelNames(github.setIssueLabels($f.github, $repo, $number, $names));
            }
            when "gitlab" { return gitlab.setIssueLabels($f.gitlab, $repo, $number, $names).labels; }
            when "forgejo" {
                forgejoCheckNames($f, $names);
                def got as list of string init forgejoLabelNames(forgejo.setIssueLabels(
                    $f.forgejo,
                    $repo,
                    $number,
                    $names));
                return forgejoCompleted($f, $repo, $number, $names, $got);
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Add labels to an issue (on GitHub and Forgejo also to a pull request). A
 * name that is no label yet creates one, as for `setIssueLabels`.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @param names {list of string} label names, at least one
 * @return {list of string} the issue's label names now
 * @throws {CodehostError} kind `"codehost"` on no or an empty name, or a
 *   name with a comma on GitLab
 */
export func addIssueLabels(f as Forge, repo as string, number as int, names as list of string) {
    try {
        checkNumber($f, $number);
        if (len($names) == 0) {
            fail($f, "adding labels names at least one");
        }
        match ($f.backend) {
            when "github" {
                return githubLabelNames(github.addIssueLabels($f.github, $repo, $number, $names));
            }
            when "gitlab" { return gitlab.addIssueLabels($f.gitlab, $repo, $number, $names).labels; }
            when "forgejo" {
                forgejoCheckNames($f, $names);
                def got as list of string init forgejoLabelNames(forgejo.addIssueLabels(
                    $f.forgejo,
                    $repo,
                    $number,
                    $names));
                return forgejoCompleted($f, $repo, $number, $names, $got);
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Take a label off an issue (on GitHub and Forgejo also off a pull
 * request).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} the issue number
 * @param name {string} the label name
 * @throws {CodehostError} kind `"codehost"` on an empty name; GitHub
 *   answers 404 when the issue does not have the label, GitLab and Forgejo
 *   do not mind (on Forgejo and Gitea the deck reads the issue's labels for
 *   the label's id)
 */
export func removeIssueLabel(f as Forge, repo as string, number as int, name as string) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" {
                github.removeIssueLabel($f.github, $repo, $number, $name);
                return;
            }
            when "gitlab" {
                gitlab.removeIssueLabel($f.gitlab, $repo, $number, $name);
                return;
            }
            when "forgejo" {
                forgejo.removeIssueLabel($f.forgejo, $repo, $number, $name);
                return;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- change requests --------------------------------------------------------

# undrafted is a title without the draft prefix `pattern` matches, which
# GitLab and Forgejo keep in it.
func undrafted(pattern as string, title as string) {
    return regex.replace($pattern, $title, "");
}

# githubChange normalises a GitHub pull request. GitHub reports a draft and
# a closed one as mergeable; neither can be merged.
func githubChange(p as github.PullRequest) {
    def state as string init $p.state;
    def sha as string init "";
    if ($p.merged) {
        $state = "merged";
        $sha = $p.mergeSha;
    }
    return ChangeRequest{
        number: $p.number,
        title: $p.title,
        body: $p.body,
        state: $state,
        author: $p.author,
        head: $p.head,
        base: $p.base,
        headSha: $p.headSha,
        isDraft: $p.isDraft,
        mergeable: $p.mergeable and $state == "open" and not $p.isDraft,
        mergeSha: $sha,
        htmlUrl: $p.htmlUrl
    };
}

# gitlabChange normalises a GitLab merge request. A fast-forward merge
# leaves no merge commit: the head commit is then what landed.
func gitlabChange(m as gitlab.MergeRequest) {
    def sha as string init "";
    if ($m.merged) {
        $sha = $m.mergeSha;
        if ($sha == "") {
            $sha = $m.squashSha;
        }
        if ($sha == "") {
            $sha = $m.sha;
        }
    }
    def title as string init $m.title;
    if ($m.isDraft) {
        $title = undrafted(GITLAB_DRAFT, $title);
    }
    def state as string init openState($m.state);
    return ChangeRequest{
        number: $m.iid,
        title: $title,
        body: $m.description,
        state: $state,
        author: $m.author,
        head: $m.sourceBranch,
        base: $m.targetBranch,
        headSha: $m.sha,
        isDraft: $m.isDraft,
        mergeable: $m.mergeable and $state == "open" and not $m.isDraft,
        mergeSha: $sha,
        htmlUrl: $m.webUrl
    };
}

# forgejoChange normalises a Forgejo pull request. A Forgejo older than its
# `draft` member marks a draft by its title alone, with the default `WIP:` or
# `[WIP]`. Forgejo reports a merged or closed one as mergeable.
func forgejoChange(p as forgejo.PullRequest) {
    def state as string init $p.state;
    def sha as string init "";
    if ($p.merged) {
        $state = "merged";
        $sha = $p.mergeSha;
    }
    def draft as bool init $p.isDraft or regex.matches(FORGEJO_DRAFT, $p.title);
    def title as string init $p.title;
    if ($draft) {
        $title = undrafted(DRAFT_PREFIX, $title);
    }
    return ChangeRequest{
        number: $p.number,
        title: $title,
        body: $p.body,
        state: $state,
        author: $p.author,
        head: $p.head,
        base: $p.base,
        headSha: $p.headSha,
        isDraft: $draft,
        mergeable: $p.mergeable and $state == "open" and not $draft,
        mergeSha: $sha,
        htmlUrl: $p.htmlUrl
    };
}

# withState keeps the change requests in one state.
func withState(found as list of ChangeRequest, state as string) {
    def out as list of ChangeRequest init [];
    for (def c in $found) {
        if ($c.state == $state) {
            $out[] = $c;
        }
    }
    return $out;
}

/**
 * The change requests of a repository, newest first.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param state {string} `open`, `closed` (closed without merging),
 *   `merged` or `all`
 * @return {list of ChangeRequest} the change requests
 * @throws {CodehostError} kind `"codehost"` on another state
 * @throws {Error} kind `"limit"` past the backend's page cap
 */
export func changeRequests(f as Forge, repo as string, state as string) {
    def out as list of ChangeRequest init [];
    try {
        if (not lists.contains(["open", "closed", "merged", "all"], $state)) {
            fail($f, "a change request state is open, closed, merged or all, got " +
                shown($state));
        }
        # GitHub and Forgejo list merged ones as closed.
        def asked as string init $state;
        if ($state == "merged") {
            $asked = "closed";
        }
        match ($f.backend) {
            when "github" {
                for (def p in github.pullRequests($f.github, $repo, $asked)) {
                    $out[] = githubChange($p);
                }
            }
            when "gitlab" {
                $asked = $state;
                if ($state == "open") {
                    $asked = "opened";
                }
                for (def m in gitlab.mergeRequests($f.gitlab, $repo, $asked)) {
                    $out[] = gitlabChange($m);
                }
                return $out;
            }
            when "forgejo" {
                for (def p in forgejo.pullRequests($f.forgejo, $repo, $asked)) {
                    $out[] = forgejoChange($p);
                }
            }
            else { noBackend($f); }
        }
        if ($state == "closed" or $state == "merged") {
            return withState($out, $state);
        }
        return $out;
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * One change request.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} its number (GitLab's `iid`)
 * @return {ChangeRequest} the change request
 * @throws {CodehostError} kind `"codehost"` when it does not exist (HTTP 404)
 */
export func changeRequest(f as Forge, repo as string, number as int) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" { return githubChange(github.pullRequest($f.github, $repo, $number)); }
            when "gitlab" { return gitlabChange(gitlab.mergeRequest($f.gitlab, $repo, $number)); }
            when "forgejo" { return forgejoChange(forgejo.pullRequest($f.forgejo, $repo, $number)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# repoPath is `/repos/owner/name` for a raw GitHub or Forgejo call, checked
# as the backend decks check it.
func repoPath(f as Forge, repo as string) {
    def parts as list of string init strings.split($repo, "/");
    def good as bool init len($parts) == 2;
    for (def part in $parts) {
        if (not regex.matches(NAME_PATTERN, $part) or $part == "." or $part == "..") {
            $good = false;
        }
    }
    if (not $good) {
        fail($f, "a repository is owner/name, got " + shown($repo));
    }
    return "/repos/" + $repo;
}

/**
 * Open a change request.
 *
 * GitHub opens a draft as one; GitLab and Forgejo mark a draft by its title,
 * so the deck puts `Draft: ` (GitLab) or `WIP: ` (Forgejo) in front of it,
 * unless the title starts with a prefix that forge reads as a draft already
 * (GitLab `Draft:`, `[Draft]`, `(Draft)`; Forgejo `WIP:`, `[WIP]`). With
 * `isDraft` false such a title is refused, since that forge would open a
 * draft anyway; another forge's prefix is ordinary text (`WIP:` on GitLab,
 * `Draft:` on Forgejo, either on GitHub).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param head {string} the branch with the changes; on GitHub and Forgejo
 *   `user:branch` for a fork
 * @param base {string} the branch to merge into
 * @param title {string} the title
 * @param body {string} the text, Markdown; "" for none
 * @param isDraft {bool} open it as a draft
 * @return {ChangeRequest} the new change request
 * @throws {CodehostError} kind `"codehost"` on an empty title or branch, a
 *   title the forge reads as a draft with `isDraft` false (status 0, before
 *   any request), when there is nothing to merge or one is open already
 *   (GitHub 422, GitLab 409, Forgejo 409)
 */
export func createChangeRequest(
    f as Forge,
    repo as string,
    head as string,
    base as string,
    title as string,
    body as string,
    isDraft as bool) {
    if (not $isDraft) {
        def prefixes as string init "";
        if ($f.backend == "gitlab" and regex.matches(GITLAB_DRAFT, $title)) {
            $prefixes = "Draft:, [Draft] or (Draft)";
        } elseif ($f.backend == "forgejo" and regex.matches(FORGEJO_DRAFT, $title)) {
            $prefixes = "WIP: or [WIP]";
        }
        if ($prefixes != "") {
            fail(
                $f,
                "a title starting with " + $prefixes + " makes a draft on " + $f.backend +
                    ": pass isDraft true or reword the title");
        }
    }
    try {
        def marked as string init $title;
        match ($f.backend) {
            when "github" {
                return githubChange(github.createPullRequest(
                    $f.github,
                    $repo,
                    $head,
                    $base,
                    $title,
                    $body,
                    $isDraft));
            }
            when "gitlab" {
                if ($isDraft and not regex.matches(GITLAB_DRAFT, $title) and
                    strings.trim($title) != "") {
                    $marked = "Draft: " + $title;
                }
                return gitlabChange(gitlab.createMergeRequest(
                    $f.gitlab,
                    $repo,
                    $head,
                    $base,
                    $marked,
                    $body));
            }
            when "forgejo" {
                if ($isDraft and not regex.matches(FORGEJO_DRAFT, $title) and
                    strings.trim($title) != "") {
                    $marked = "WIP: " + $title;
                }
                return forgejoChange(forgejo.createPullRequest(
                    $f.forgejo,
                    $repo,
                    $head,
                    $base,
                    $marked,
                    $body));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Close a change request without merging it.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} its number
 * @return {ChangeRequest} the change request
 * @throws {CodehostError} kind `"codehost"` when it does not exist (HTTP 404)
 */
export func closeChangeRequest(f as Forge, repo as string, number as int) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" {
                github.closeIssue($f.github, $repo, $number);
                return githubChange(github.pullRequest($f.github, $repo, $number));
            }
            when "gitlab" {
                return gitlabChange(gitlab.closeMergeRequest($f.gitlab, $repo, $number));
            }
            when "forgejo" {
                forgejo.closeIssue($f.forgejo, $repo, $number);
                return forgejoChange(forgejo.pullRequest($f.forgejo, $repo, $number));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Reopen a closed change request.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} its number
 * @return {ChangeRequest} the change request
 * @throws {CodehostError} kind `"codehost"` when it does not exist (HTTP
 *   404), or when it is merged or its branch is gone (HTTP 422)
 */
export func reopenChangeRequest(f as Forge, repo as string, number as int) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" {
                github.reopenIssue($f.github, $repo, $number);
                return githubChange(github.pullRequest($f.github, $repo, $number));
            }
            when "gitlab" {
                return gitlabChange(gitlab.reopenMergeRequest($f.gitlab, $repo, $number));
            }
            when "forgejo" {
                forgejo.reopenIssue($f.forgejo, $repo, $number);
                return forgejoChange(forgejo.pullRequest($f.forgejo, $repo, $number));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# gitlabSameProject says whether a merge request's source branch lives in
# its target project (not in a fork).
func gitlabSameProject(f as Forge, repo as string, number as int) {
    def mr as gitlab.MergeRequest init gitlab.mergeRequest($f.gitlab, $repo, $number);
    return $mr.sourceProjectId != 0 and $mr.sourceProjectId == $mr.targetProjectId;
}

# forgejoSameRepository says whether a pull request's head branch lives in
# its base repository (not in a fork).
func forgejoSameRepository(f as Forge, repo as string, number as int) {
    def head as string init forgejo.pullRequest($f.forgejo, $repo, $number).headRepo;
    return $head != "" and strings.lower($head) == strings.lower($repo);
}

/**
 * Merge a change request.
 *
 * `merge` makes a merge commit (on GitLab: merges with the project's merge
 * method, which may be a fast-forward), `squash` squashes the commits into
 * one, `rebase` puts them on the base branch one by one (GitHub and Forgejo
 * only; GitLab rebases by its project setting, not per merge, and is
 * refused). With `deleteBranch`, the head branch is deleted afterwards when
 * it lives in the same repository; a fork's branch is never touched. A
 * branch the forge deletes on its own (GitHub's "automatically delete head
 * branches", a GitLab merge request created with "delete source branch")
 * goes either way. GitLab deletes it in the background, a moment after the
 * merge returns.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} its number
 * @param style {string} one of `MERGE_STYLES`
 * @param deleteBranch {bool} delete the head branch afterwards
 * @throws {CodehostError} kind `"codehost"` on an unknown style, `rebase`
 *   on GitLab, when it cannot be merged (HTTP 405: a draft, conflicts,
 *   missing approvals) or its head moved (HTTP 409)
 */
export func mergeChangeRequest(
    f as Forge,
    repo as string,
    number as int,
    style as string,
    deleteBranch as bool) {
    try {
        checkNumber($f, $number);
        if (not lists.contains(MERGE_STYLES, $style)) {
            fail($f, "a merge style is merge, squash or rebase, got " + shown($style));
        }
        match ($f.backend) {
            when "github" {
                github.mergePullRequest($f.github, $repo, $number, $style, $deleteBranch);
                return;
            }
            when "gitlab" {
                if ($style == "rebase") {
                    fail(
                        $f,
                        "GitLab merges with the project's merge method; " +
                            "rebase is a project setting there, not a merge style");
                }
                def remove as bool init $deleteBranch and gitlabSameProject($f, $repo, $number);
                gitlab.mergeMergeRequest(
                    $f.gitlab,
                    $repo,
                    $number,
                    "",
                    $style == "squash",
                    $remove);
                return;
            }
            when "forgejo" {
                def remove as bool init $deleteBranch and
                    forgejoSameRepository($f, $repo, $number);
                forgejo.mergePullRequest($f.forgejo, $repo, $number, $style, $remove);
                return;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * The comments on a change request, oldest first: the conversation, not the
 * review comments on lines of code. GitLab's system notes are left out.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} its number
 * @return {list of Comment} the comments
 * @throws {CodehostError} kind `"codehost"` when it does not exist
 */
export func changeRequestComments(f as Forge, repo as string, number as int) {
    def out as list of Comment init [];
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" {
                for (def c in github.comments($f.github, $repo, $number)) {
                    $out[] = githubComment($c);
                }
                return $out;
            }
            when "gitlab" {
                return gitlabComments(gitlab.mergeRequestNotes($f.gitlab, $repo, $number));
            }
            when "forgejo" {
                for (def c in forgejo.comments($f.forgejo, $repo, $number)) {
                    $out[] = forgejoComment($c);
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Comment on a change request.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param number {int} its number
 * @param body {string} the text, Markdown
 * @return {Comment} the new comment
 * @throws {CodehostError} kind `"codehost"` on an empty text
 */
export func commentChangeRequest(f as Forge, repo as string, number as int, body as string) {
    try {
        checkNumber($f, $number);
        match ($f.backend) {
            when "github" { return githubComment(github.comment($f.github, $repo, $number, $body)); }
            when "gitlab" {
                return gitlabComment(gitlab.addMergeRequestNote($f.gitlab, $repo, $number, $body));
            }
            when "forgejo" {
                return forgejoComment(forgejo.comment($f.forgejo, $repo, $number, $body));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- releases ---------------------------------------------------------------

# githubAsset normalises a GitHub release asset.
func githubAsset(a as github.Asset) {
    return Asset{
        id: $a.id,
        name: $a.name,
        contentType: $a.contentType,
        size: $a.size,
        downloads: $a.downloads,
        downloadUrl: $a.downloadUrl,
        apiUrl: $a.apiUrl
    };
}

# gitlabAsset normalises a GitLab release link.
func gitlabAsset(l as gitlab.ReleaseLink) {
    def page as string init $l.directAssetUrl;
    if ($page == "") {
        $page = $l.url;
    }
    return Asset{
        id: $l.id,
        name: $l.name,
        contentType: "",
        size: 0,
        downloads: 0,
        downloadUrl: $page,
        apiUrl: $l.url
    };
}

# forgejoAsset normalises a Forgejo release asset.
func forgejoAsset(a as forgejo.Asset) {
    return Asset{
        id: $a.id,
        name: $a.name,
        contentType: "",
        size: $a.size,
        downloads: $a.downloads,
        downloadUrl: $a.downloadUrl,
        apiUrl: $a.downloadUrl
    };
}

# githubRelease normalises a GitHub release.
func githubRelease(r as github.Release) {
    def assets as list of Asset init [];
    for (def a in $r.assets) {
        $assets[] = githubAsset($a);
    }
    return Release{
        id: $r.id,
        tag: $r.tag,
        name: $r.name,
        body: $r.body,
        isDraft: $r.isDraft,
        isPrerelease: $r.isPrerelease,
        created: $r.created,
        published: $r.published,
        htmlUrl: $r.htmlUrl,
        assets: $assets
    };
}

# gitlabRelease normalises a GitLab release.
func gitlabRelease(r as gitlab.Release) {
    def assets as list of Asset init [];
    for (def l in $r.links) {
        $assets[] = gitlabAsset($l);
    }
    return Release{
        id: 0,
        tag: $r.tag,
        name: $r.name,
        body: $r.description,
        isDraft: false,
        isPrerelease: false,
        created: $r.created,
        published: $r.released,
        htmlUrl: $r.webUrl,
        assets: $assets
    };
}

# forgejoRelease normalises a Forgejo release. Forgejo reports a draft's
# creation time as published; GitHub reports none.
func forgejoRelease(r as forgejo.Release) {
    def assets as list of Asset init [];
    for (def a in $r.assets) {
        $assets[] = forgejoAsset($a);
    }
    def published as string init $r.published;
    if ($r.isDraft) {
        $published = "";
    }
    return Release{
        id: $r.id,
        tag: $r.tag,
        name: $r.name,
        body: $r.body,
        isDraft: $r.isDraft,
        isPrerelease: $r.isPrerelease,
        created: $r.created,
        published: $published,
        htmlUrl: $r.htmlUrl,
        assets: $assets
    };
}

/**
 * The releases of a repository, newest first. GitHub lists drafts only to a
 * token with push access.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @return {list of Release} the releases
 * @throws {CodehostError} kind `"codehost"` when the repository does not
 *   exist
 * @throws {Error} kind `"limit"` past the backend's page cap
 */
export func releases(f as Forge, repo as string) {
    def out as list of Release init [];
    try {
        match ($f.backend) {
            when "github" {
                for (def r in github.releases($f.github, $repo)) {
                    $out[] = githubRelease($r);
                }
                return $out;
            }
            when "gitlab" {
                for (def r in gitlab.releases($f.gitlab, $repo)) {
                    $out[] = gitlabRelease($r);
                }
                return $out;
            }
            when "forgejo" {
                for (def r in forgejo.releases($f.forgejo, $repo)) {
                    $out[] = forgejoRelease($r);
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * The release of a tag.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param tag {string} the tag, e.g. `1.2.0`
 * @return {Release} the release
 * @throws {CodehostError} kind `"codehost"` when there is none (HTTP 404)
 */
export func release(f as Forge, repo as string, tag as string) {
    try {
        match ($f.backend) {
            when "github" { return githubRelease(github.release($f.github, $repo, $tag)); }
            when "gitlab" { return gitlabRelease(gitlab.release($f.gitlab, $repo, $tag)); }
            when "forgejo" { return forgejoRelease(forgejo.release($f.forgejo, $repo, $tag)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * The latest release: on GitHub and Forgejo the newest that is neither a
 * draft nor a pre-release (GitHub's "latest" mark), on GitLab the one with
 * the latest release date that is not in the future.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @return {Release} the release
 * @throws {CodehostError} kind `"codehost"` when there is none (HTTP 404)
 */
export func latestRelease(f as Forge, repo as string) {
    try {
        match ($f.backend) {
            when "github" { return githubRelease(github.latestRelease($f.github, $repo)); }
            when "gitlab" { return gitlabRelease(gitlab.latestRelease($f.gitlab, $repo)); }
            when "forgejo" { return forgejoRelease(forgejo.latestRelease($f.forgejo, $repo)); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# gitlabDefaultBranch is the project's default branch, for a ref of "".
func gitlabDefaultBranch(f as Forge, repo as string, ref as string) {
    if ($ref != "") {
        return $ref;
    }
    def branch as string init gitlab.project($f.gitlab, $repo).defaultBranch;
    if ($branch == "") {
        fail($f, "the project " + shown($repo) + " has no default branch; name one");
    }
    return $branch;
}

/**
 * Publish a release, creating the tag at `target` when it does not exist.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param tag {string} the tag, e.g. `1.2.0`
 * @param target {string} the branch or commit to tag when the tag does not
 *   exist; "" for the default branch
 * @param name {string} the title; "" for the tag
 * @param body {string} the notes, Markdown; "" for none
 * @param isPrerelease {bool} mark it as a pre-release; GitLab has none and
 *   refuses true
 * @return {Release} the new release
 * @throws {CodehostError} kind `"codehost"` on a bad tag, a pre-release on
 *   GitLab, or when the tag has a release already (GitHub 422, GitLab 409)
 */
export func createRelease(
    f as Forge,
    repo as string,
    tag as string,
    target as string,
    name as string,
    body as string,
    isPrerelease as bool) {
    try {
        match ($f.backend) {
            when "github" {
                return githubRelease(github.createRelease(
                    $f.github,
                    $repo,
                    $tag,
                    $target,
                    $name,
                    $body,
                    $isPrerelease));
            }
            when "gitlab" {
                if ($isPrerelease) {
                    fail($f, "GitLab has no pre-releases");
                }
                def ref as string init gitlabDefaultBranch($f, $repo, $target);
                return gitlabRelease(gitlab.createRelease(
                    $f.gitlab,
                    $repo,
                    $tag,
                    $ref,
                    $name,
                    $body));
            }
            when "forgejo" {
                return forgejoRelease(forgejo.createRelease(
                    $f.forgejo,
                    $repo,
                    $tag,
                    $target,
                    $name,
                    $body,
                    $isPrerelease));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# packageName is the generic package GitLab assets go to: the project's last
# path segment.
func packageName(repo as string) {
    def parts as list of string init strings.split($repo, "/");
    return $parts[len($parts) - 1];
}

/**
 * Attach a file to a release.
 *
 * On GitLab the file goes to the project's generic package registry, as
 * `<project>/<tag>/<name>` (`<project>` the last segment of its path), and
 * a `package` link to it is attached to the release, as `glab` does it;
 * there the tag and the name take letters, digits and `._+-` (the name also
 * `~@`).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param release {Release} the release, from `release` or `createRelease`
 * @param name {string} the file name
 * @param data {bytes} the content
 * @return {Asset} the new asset
 * @throws {CodehostError} kind `"codehost"` on a bad name, or when the
 *   release has a file of that name
 */
export func uploadAsset(
    f as Forge,
    repo as string,
    release as Release,
    name as string,
    data as bytes) {
    try {
        match ($f.backend) {
            when "github" {
                return githubAsset(github.uploadAsset(
                    $f.github,
                    $repo,
                    $release.id,
                    $name,
                    "",
                    $data));
            }
            when "gitlab" {
                return gitlabAsset(gitlab.uploadAsset(
                    $f.gitlab,
                    $repo,
                    $release.tag,
                    packageName($repo),
                    $name,
                    $data));
            }
            when "forgejo" {
                return forgejoAsset(forgejo.uploadAsset(
                    $f.forgejo,
                    $repo,
                    $release.id,
                    $name,
                    $data));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Download a release asset stored on the forge, with the client's token, so
 * it works for a private repository too. The token goes to the forge's own
 * address only: GitHub's redirect to its storage is followed without it,
 * and an asset whose URL lies elsewhere (common for GitLab release links)
 * is refused; fetch that one with `http` yourself.
 *
 * @param f {Forge} the forge
 * @param asset {Asset} the asset, from a `Release`
 * @param maxBytes {int} the largest file accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the content
 * @throws {CodehostError} kind `"codehost"` for an asset elsewhere, or on a
 *   refusal
 * @throws {Error} kind `"limit"` for a file over `maxBytes`
 */
export func downloadAsset(f as Forge, asset as Asset, maxBytes as int) {
    try {
        match ($f.backend) {
            when "github" {
                def a as github.Asset init github.Asset{
                    id: $asset.id,
                    name: $asset.name,
                    contentType: $asset.contentType,
                    size: $asset.size,
                    downloads: $asset.downloads,
                    downloadUrl: $asset.downloadUrl,
                    apiUrl: $asset.apiUrl
                };
                return github.downloadAsset($f.github, $a, $maxBytes);
            }
            when "gitlab" {
                def l as gitlab.ReleaseLink init gitlab.ReleaseLink{
                    id: $asset.id,
                    name: $asset.name,
                    url: $asset.apiUrl,
                    directAssetUrl: $asset.downloadUrl,
                    linkType: ""
                };
                return gitlab.downloadAsset($f.gitlab, $l, $maxBytes);
            }
            when "forgejo" {
                def a as forgejo.Asset init forgejo.Asset{
                    id: $asset.id,
                    name: $asset.name,
                    size: $asset.size,
                    downloads: $asset.downloads,
                    downloadUrl: $asset.apiUrl
                };
                return forgejo.downloadAsset($f.forgejo, $a, $maxBytes);
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- branches and tags ------------------------------------------------------

/**
 * The branches of a repository.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @return {list of Branch} the branches
 * @throws {CodehostError} kind `"codehost"` when the repository does not
 *   exist
 */
export func branches(f as Forge, repo as string) {
    def out as list of Branch init [];
    try {
        match ($f.backend) {
            when "github" {
                for (def b in github.branches($f.github, $repo)) {
                    $out[] = Branch{name: $b.name, sha: $b.sha, isProtected: $b.isProtected};
                }
                return $out;
            }
            when "gitlab" {
                for (def b in gitlab.branches($f.gitlab, $repo)) {
                    $out[] = Branch{name: $b.name, sha: $b.sha, isProtected: $b.isProtected};
                }
                return $out;
            }
            when "forgejo" {
                for (def b in forgejo.branches($f.forgejo, $repo)) {
                    $out[] = Branch{name: $b.name, sha: $b.sha, isProtected: $b.isProtected};
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Create a branch.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param name {string} the new branch
 * @param from {string} the branch, tag or commit it starts at; "" for the
 *   default branch
 * @return {Branch} the new branch
 * @throws {CodehostError} kind `"codehost"` on a bad name, or when it exists
 *   (GitHub 422, GitLab 400, Forgejo 409)
 */
export func createBranch(f as Forge, repo as string, name as string, from as string) {
    try {
        match ($f.backend) {
            when "github" {
                def b as github.Branch init github.createBranch($f.github, $repo, $name, $from);
                return Branch{name: $b.name, sha: $b.sha, isProtected: $b.isProtected};
            }
            when "gitlab" {
                def start as string init gitlabDefaultBranch($f, $repo, $from);
                def b as gitlab.Branch init gitlab.createBranch($f.gitlab, $repo, $name, $start);
                return Branch{name: $b.name, sha: $b.sha, isProtected: $b.isProtected};
            }
            when "forgejo" {
                def b as forgejo.Branch init forgejo.createBranch($f.forgejo, $repo, $name, $from);
                return Branch{name: $b.name, sha: $b.sha, isProtected: $b.isProtected};
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Delete a branch.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param name {string} the branch
 * @throws {CodehostError} kind `"codehost"` when it is protected or the
 *   default branch, or does not exist
 */
export func deleteBranch(f as Forge, repo as string, name as string) {
    try {
        match ($f.backend) {
            when "github" {
                github.deleteBranch($f.github, $repo, $name);
                return;
            }
            when "gitlab" {
                gitlab.deleteBranch($f.gitlab, $repo, $name);
                return;
            }
            when "forgejo" {
                forgejo.deleteBranch($f.forgejo, $repo, $name);
                return;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * The tags of a repository.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @return {list of Tag} the tags; GitHub's listing carries no annotations
 * @throws {CodehostError} kind `"codehost"` when the repository does not
 *   exist
 */
export func tags(f as Forge, repo as string) {
    def out as list of Tag init [];
    try {
        match ($f.backend) {
            when "github" {
                for (def t in github.tags($f.github, $repo)) {
                    $out[] = Tag{name: $t.name, sha: $t.sha, message: $t.message};
                }
                return $out;
            }
            when "gitlab" {
                for (def t in gitlab.tags($f.gitlab, $repo)) {
                    $out[] = Tag{name: $t.name, sha: $t.sha, message: $t.message};
                }
                return $out;
            }
            when "forgejo" {
                for (def t in forgejo.tags($f.forgejo, $repo)) {
                    $out[] = Tag{name: $t.name, sha: $t.sha, message: $t.message};
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Create a tag: a lightweight one, or with a message an annotated one.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param name {string} the tag, e.g. `1.2.0`
 * @param target {string} the branch, tag or commit to tag; "" for the
 *   default branch
 * @param message {string} the annotation; "" for a lightweight tag
 * @return {Tag} the new tag
 * @throws {CodehostError} kind `"codehost"` on a bad name, or when it exists
 */
export func createTag(
    f as Forge,
    repo as string,
    name as string,
    target as string,
    message as string) {
    try {
        match ($f.backend) {
            when "github" {
                def t as github.Tag init github.createTag(
                    $f.github,
                    $repo,
                    $name,
                    $target,
                    $message);
                return Tag{name: $t.name, sha: $t.sha, message: $t.message};
            }
            when "gitlab" {
                def ref as string init gitlabDefaultBranch($f, $repo, $target);
                def t as gitlab.Tag init gitlab.createTag($f.gitlab, $repo, $name, $ref, $message);
                return Tag{name: $t.name, sha: $t.sha, message: $t.message};
            }
            when "forgejo" {
                def t as forgejo.Tag init forgejo.createTag(
                    $f.forgejo,
                    $repo,
                    $name,
                    $target,
                    $message);
                return Tag{name: $t.name, sha: $t.sha, message: $t.message};
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Delete a tag. A release of it stays (on GitHub and Forgejo as a draft).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param name {string} the tag
 * @throws {CodehostError} kind `"codehost"` when it is protected or does
 *   not exist
 */
export func deleteTag(f as Forge, repo as string, name as string) {
    try {
        match ($f.backend) {
            when "github" {
                github.deleteTag($f.github, $repo, $name);
                return;
            }
            when "gitlab" {
                gitlab.deleteTag($f.gitlab, $repo, $name);
                return;
            }
            when "forgejo" {
                forgejo.deleteTag($f.forgejo, $repo, $name);
                return;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- files ------------------------------------------------------------------

/**
 * Read a file from a repository, as its bytes. A file in Git LFS comes as
 * its content on GitLab and Forgejo, as its pointer on GitHub.
 *
 * `maxBytes` is `downloadAsset`'s: 0 for 64 MiB, negative for no limit.
 * GitHub refuses a cap over 100 MB (its raw limit, `github.MAX_FILE_BYTES`);
 * the forgejo deck reads at most 64 MiB whatever the cap, and a smaller cap
 * is checked once the file is read.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param path {string} the file, e.g. `docs/index.md`
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @param maxBytes {int} the largest file accepted; 0 for 64 MiB, negative
 *   for no limit
 * @return {bytes} the content
 * @throws {CodehostError} kind `"codehost"` when it does not exist or is a
 *   directory, or for a GitHub cap over 100 MB (status 0)
 * @throws {Error} kind `"limit"` for a file over `maxBytes` (on Forgejo
 *   over 64 MiB too)
 * @example
 *   def v as bytes init codehost.readFile($f, "me/app", "VERSION", "main", 4096);
 */
export func readFile(f as Forge, repo as string, path as string, ref as string, maxBytes as int) {
    try {
        match ($f.backend) {
            when "github" { return github.readFile($f.github, $repo, $path, $ref, $maxBytes); }
            when "gitlab" { return gitlab.readFile($f.gitlab, $repo, $path, $ref, $maxBytes); }
            when "forgejo" {
                def data as bytes init forgejo.readFile($f.forgejo, $repo, $path, $ref);
                if ($maxBytes > 0 and len($data) > $maxBytes) {
                    throw Error{
                        kind: "limit",
                        message: "codehost: " + shown($path) + " is over maxBytes, " +
                            convert.toString($maxBytes) + " bytes"
                    };
                }
                return $data;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Create or replace a file with a commit of its own.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param path {string} the file, e.g. `data/version.txt`
 * @param data {bytes} the new content
 * @param message {string} the commit message
 * @param branch {string} the branch to commit to; "" for the default branch
 * @return {string} the new commit's SHA
 * @throws {CodehostError} kind `"codehost"` on an empty message or a bad
 *   path, or when the branch moved meanwhile (GitHub 409)
 */
export func writeFile(
    f as Forge,
    repo as string,
    path as string,
    data as bytes,
    message as string,
    branch as string) {
    try {
        match ($f.backend) {
            when "github" {
                return github.writeFile($f.github, $repo, $path, $data, $message, $branch);
            }
            when "gitlab" {
                return gitlab.writeFile($f.gitlab, $repo, $path, $data, $message, $branch);
            }
            when "forgejo" {
                return forgejo.writeFile($f.forgejo, $repo, $path, $data, $message, $branch);
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Delete a file with a commit of its own.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param path {string} the file
 * @param message {string} the commit message
 * @param branch {string} the branch to commit to; "" for the default branch
 * @return {string} the new commit's SHA
 * @throws {CodehostError} kind `"codehost"` on an empty message, or when
 *   the file does not exist
 */
export func deleteFile(
    f as Forge,
    repo as string,
    path as string,
    message as string,
    branch as string) {
    try {
        match ($f.backend) {
            when "github" { return github.deleteFile($f.github, $repo, $path, $message, $branch); }
            when "gitlab" { return gitlab.deleteFile($f.gitlab, $repo, $path, $message, $branch); }
            when "forgejo" { return forgejo.deleteFile($f.forgejo, $repo, $path, $message, $branch); }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# gitEntryType maps a git tree entry type (GitLab's tree, GitHub's git/trees)
# to the contents API's names: `blob` is a file (a symlink by its mode),
# `tree` a directory, `commit` a submodule.
func gitEntryType(type as string, mode as string) {
    match ($type) {
        when "blob" { if ($mode == "120000") {
            return "symlink";
        }
        return "file"; }
        when "tree" { return "dir"; }
        when "commit" { return "submodule"; }
    }
    return $type;
}

# githubDirectory lists a GitHub directory with its real entry types. The
# contents API names a symlink and a submodule `file` in a listing (seen live
# on git/git), so the entries come from the directory's git tree, whose modes
# tell them apart. The tree's sha comes from the parent's listing, or for the
# root from the newest commit on the ref: two documented requests, one more
# than the contents API alone.
func githubDirectory(f as Forge, repo as string, path as string, ref as string) {
    def base as string init repoPath($f, $repo);
    def treeSha as string init "";
    if ($path == "") {
        def q as string init $base + "/commits?per_page=1";
        if ($ref != "") {
            $q = $q + "&sha=" + uri.encode($ref);
        }
        def cs as json.Value init github.call($f.github, "GET", $q, "");
        if (json.typeOf($cs) != "list" or json.length($cs) == 0) {
            fail($f, "no commit on " + shown($ref) + " to list the root of");
        }
        $treeSha = json.asString($cs, "/0/commit/tree/sha");
    } else {
        def parts as list of string init strings.split($path, "/");
        for (def part in $parts) {
            if ($part == "" or $part == "." or $part == "..") {
                fail($f, "a directory is a path of names, got " + shown($path));
            }
        }
        def name as string init $parts[len($parts) - 1];
        def parent as string init strings.join($parts[0..len($parts) - 1], "/");
        def found as bool init false;
        for (def e in github.listDirectory($f.github, $repo, $parent, $ref)) {
            if ($e.name == $name) {
                if ($e.type != "dir") {
                    fail($f, shown($path) + " is not a directory");
                }
                $treeSha = $e.sha;
                $found = true;
            }
        }
        if (not $found) {
            throw CodehostError{
                kind: ERROR_KIND,
                message: "codehost: no directory " + shown($path) + " in " + $repo,
                status: 404,
                backend: $f.backend
            };
        }
    }
    if (not regex.matches('^[0-9a-f]{40}([0-9a-f]{24})?$', $treeSha)) {
        fail($f, "GitHub sent no tree for " + shown($path));
    }
    def t as json.Value init github.call($f.github, "GET", $base + "/git/trees/" + $treeSha, "");
    if (json.has($t, "/truncated") and json.asBool($t, "/truncated")) {
        fail($f, "GitHub cut the listing of " + shown($path) + " short");
    }
    def out as list of Entry init [];
    def n as int init 0;
    if (json.has($t, "/tree")) {
        $n = json.length($t, "/tree");
    }
    for (def i in 0..$n) {
        def p as string init "/tree/" + convert.toString($i);
        def name as string init json.asString($t, $p + "/path");
        def full as string init $name;
        if ($path != "") {
            $full = $path + "/" + $name;
        }
        def size as int init 0;
        if (json.has($t, $p + "/size")) {
            $size = json.asInt($t, $p + "/size");
        }
        $out[] = Entry{
            name: $name,
            path: $full,
            type: gitEntryType(json.asString($t, $p + "/type"), json.asString($t, $p + "/mode")),
            size: $size,
            sha: json.asString($t, $p + "/sha")
        };
    }
    return $out;
}

/**
 * The entries of a directory in a repository.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param path {string} the directory; "" for the root
 * @param ref {string} a branch, tag or commit; "" for the default branch
 * @return {list of Entry} the entries; on GitHub read from the directory's
 *   git tree (two requests), since its contents listing calls a symlink and
 *   a submodule `file`
 * @throws {CodehostError} kind `"codehost"` when it does not exist or is a
 *   file
 */
export func listDirectory(f as Forge, repo as string, path as string, ref as string) {
    def out as list of Entry init [];
    try {
        match ($f.backend) {
            when "github" { return githubDirectory($f, $repo, $path, $ref); }
            when "gitlab" {
                for (def e in gitlab.listDirectory($f.gitlab, $repo, $path, $ref)) {
                    $out[] = Entry{
                        name: $e.name,
                        path: $e.path,
                        type: gitEntryType($e.type, $e.mode),
                        size: 0,
                        sha: $e.sha
                    };
                }
                return $out;
            }
            when "forgejo" {
                for (def e in forgejo.listDirectory($f.forgejo, $repo, $path, $ref)) {
                    $out[] = Entry{
                        name: $e.name,
                        path: $e.path,
                        type: $e.type,
                        size: $e.size,
                        sha: $e.sha
                    };
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

# --- commit statuses --------------------------------------------------------

# normalState maps a forge's commit-status state to one of STATUS_STATES.
# GitLab: running and the waiting states are pending, failed is failure,
# canceled is error, skipped is success. Forgejo: warning (finished, did not
# fail) and skipped are success, as GitLab's success with warnings is;
# forgeState keeps "warning" for a caller that wants it to block. Anything
# unknown is pending.
func normalState(state as string) {
    match ($state) {
        when "success", "skipped", "warning" { return "success"; }
        when "failure", "failed" { return "failure"; }
        when "error", "canceled", "cancelled" { return "error"; }
    }
    return "pending";
}

# gitlabStatusState is the GitLab state a normalised one is set as.
func gitlabStatusState(state as string) {
    match ($state) {
        when "failure" { return "failed"; }
        when "error" { return "canceled"; }
    }
    return $state;
}

# githubStatus normalises a GitHub commit status.
func githubStatus(s as github.CommitStatus) {
    return CommitStatus{
        context: $s.context,
        state: normalState($s.state),
        forgeState: $s.state,
        description: $s.description,
        targetUrl: $s.targetUrl,
        creator: $s.creator,
        created: $s.created
    };
}

# gitlabStatus normalises a GitLab commit status.
func gitlabStatus(s as gitlab.CommitStatus) {
    return CommitStatus{
        context: $s.name,
        state: normalState($s.status),
        forgeState: $s.status,
        description: $s.description,
        targetUrl: $s.targetUrl,
        creator: $s.author,
        created: $s.created
    };
}

# forgejoStatus normalises a Forgejo commit status.
func forgejoStatus(s as forgejo.CommitStatus) {
    return CommitStatus{
        context: $s.context,
        state: normalState($s.state),
        forgeState: $s.state,
        description: $s.description,
        targetUrl: $s.targetUrl,
        creator: $s.creator,
        created: $s.created
    };
}

/**
 * Set a status on a commit, as a CI system reports a check.
 *
 * GitLab has no `failure` or `error`: they are set as `failed` and
 * `canceled`, and GitLab refuses some moves, such as from `success` back to
 * `pending` (HTTP 400).
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param sha {string} the commit SHA
 * @param state {string} one of `STATUS_STATES`
 * @param context {string} which check it is, e.g. `ci/build`
 * @param description {string} a short text; "" for none
 * @param targetUrl {string} where the details are; "" for none
 * @return {CommitStatus} the status
 * @throws {CodehostError} kind `"codehost"` on another state or a bad SHA
 * @example
 *   codehost.setCommitStatus($f, "me/app", $sha, "success", "ci/build", "built in 42 s", $logUrl);
 */
export func setCommitStatus(
    f as Forge,
    repo as string,
    sha as string,
    state as string,
    context as string,
    description as string,
    targetUrl as string) {
    try {
        if (not lists.contains(STATUS_STATES, $state)) {
            fail(
                $f,
                "a commit status is one of " + strings.join(STATUS_STATES, ", ") + ", got " +
                    shown($state));
        }
        match ($f.backend) {
            when "github" {
                return githubStatus(github.setCommitStatus(
                    $f.github,
                    $repo,
                    $sha,
                    $state,
                    $context,
                    $description,
                    $targetUrl));
            }
            when "gitlab" {
                return gitlabStatus(gitlab.setCommitStatus(
                    $f.gitlab,
                    $repo,
                    $sha,
                    gitlabStatusState($state),
                    $context,
                    $description,
                    $targetUrl));
            }
            when "forgejo" {
                return forgejoStatus(forgejo.setCommitStatus(
                    $f.forgejo,
                    $repo,
                    $sha,
                    $state,
                    $context,
                    $description,
                    $targetUrl));
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}

/**
 * Every status set on a commit, newest first, earlier ones of a context
 * included.
 *
 * @param f {Forge} the forge
 * @param repo {string} `owner/name`, or GitLab's full path
 * @param sha {string} the commit SHA
 * @return {list of CommitStatus} the statuses
 * @throws {CodehostError} kind `"codehost"` on a bad SHA, or when the
 *   commit does not exist
 */
export func commitStatuses(f as Forge, repo as string, sha as string) {
    def out as list of CommitStatus init [];
    try {
        match ($f.backend) {
            when "github" {
                for (def s in github.commitStatuses($f.github, $repo, $sha)) {
                    $out[] = githubStatus($s);
                }
                return $out;
            }
            when "gitlab" {
                for (def s in gitlab.commitStatuses($f.gitlab, $repo, $sha)) {
                    $out[] = gitlabStatus($s);
                }
                return $out;
            }
            when "forgejo" {
                for (def s in forgejo.commitStatuses($f.forgejo, $repo, $sha)) {
                    $out[] = forgejoStatus($s);
                }
                return $out;
            }
        }
    } catch (e) {
        if (passes($e.kind)) {
            throw $e;
        }
        def status as int init 0;
        try {
            $status = $e.status;
        } catch (none) {
            $status = 0;
        }
        failFrom($f, $e.kind, $e.message, $status);
    }
    noBackend($f);
}
