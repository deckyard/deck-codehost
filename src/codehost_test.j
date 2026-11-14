# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0

/**
 * The conformance suite: jennifer test src/codehost_test.j
 *
 * Every verb runs against a loopback `httpd` fake of each backend. The fake
 * answers canned GitHub, GitLab and Forgejo replies, one per request, and
 * hands back what it received, so each test checks the requests the backend
 * deck sent and that the three replies normalise to the same values. A
 * client for `http://127.0.0.1:<port>` is a GitHub Enterprise Server one,
 * so GitHub paths start with `/api/v3`, uploads with `/api/uploads`.
 */
use httpd;
use maps;
use task;
use testing;
use time;

/** A canned reply. `BASE` in a header or the body stands for the server's URL. */
def struct Reply {
    status as int,
    headers as map of string to string,
    body as string,
    delayMs as int
};

/** One request as the fake server saw it. */
def struct Seen {
    method as string,
    path as string,
    query as string,
    contentType as string,
    body as string
};

/** A running fake server. */
def struct Fake {
    srv as httpd.Server,
    url as string,
    t as task of list of Seen
};

/**
 * Answer one request per reply, in order.
 *
 * @param srv {httpd.Server} the listening server
 * @param base {string} the server's URL, for `BASE`
 * @param replies {list of Reply} the replies
 * @return {list of Seen} the requests
 */
func serve(srv as httpd.Server, base as string, replies as list of Reply) {
    def seen as list of Seen init [];
    for (def r in $replies) {
        def req as httpd.Request init httpd.accept($srv);
        def text as string init "";
        try {
            $text = convert.stringFromBytes("utf-8", httpd.body($req));
        } catch (e) {
            $text = "<binary>";
        }
        $seen[] = Seen{
            method: httpd.method($req),
            path: httpd.path($req),
            query: httpd.rawQuery($req),
            contentType: httpd.header($req, "Content-Type"),
            body: $text
        };
        if ($r.delayMs > 0) {
            time.sleep(time.fromMilliseconds($r.delayMs));
        }
        httpd.setHeader($req, "Content-Type", "application/json");
        for (def name in lists.sort(maps.keys($r.headers))) {
            httpd.setHeader($req, $name, strings.replace($r.headers[$name], "BASE", $base));
        }
        httpd.respond($req, $r.status, strings.replace($r.body, "BASE", $base));
    }
    return $seen;
}

/**
 * Start a fake server that gives these replies.
 *
 * @param replies {list of Reply} the replies
 * @return {Fake} the server
 */
func fake(replies as list of Reply) {
    def srv as httpd.Server init httpd.listen("127.0.0.1:0");
    def base as string init "http://" + httpd.address($srv);
    def t as task of list of Seen init spawn {
        return serve($srv, $base, $replies);
    };
    return Fake{srv: $srv, url: $base, t: $t};
}

/**
 * Stop a fake server.
 *
 * @param fk {Fake} the server
 * @return {list of Seen} what it received
 */
func finish(fk as Fake) {
    def seen as list of Seen init task.wait($fk.t);
    httpd.shutdown($fk.srv);
    return $seen;
}

/**
 * A 200 reply.
 *
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func ok(body as string) {
    return Reply{status: 200, headers: {}, body: $body, delayMs: 0};
}

/**
 * A reply with a status.
 *
 * @param status {int} the HTTP status
 * @param body {string} the JSON
 * @return {Reply} the reply
 */
func answer(status as int, body as string) {
    return Reply{status: $status, headers: {}, body: $body, delayMs: 0};
}

/**
 * A 200 reply of another media type.
 *
 * @param media {string} the `Content-Type`
 * @param body {string} the body
 * @return {Reply} the reply
 */
func raw(media as string, body as string) {
    return Reply{status: 200, headers: {"Content-Type": $media}, body: $body, delayMs: 0};
}

/**
 * The forge of a backend on a fake server, with a token.
 *
 * @param backend {string} `github`, `gitlab` or `forgejo`
 * @param fk {Fake} the server
 * @return {Forge} the forge
 */
func forgeOn(backend as string, fk as Fake) {
    match ($backend) {
        when "github" { return fromGithub(github.withToken(github.client($fk.url), "t0k3n")); }
        when "gitlab" { return fromGitlab(gitlab.withToken(gitlab.client($fk.url), "t0k3n")); }
    }
    return fromForgejo(forgejo.withToken(forgejo.client($fk.url), "t0k3n"));
}

/**
 * The requests as `METHOD path?query` lines, the backend first.
 *
 * @param backend {string} the backend
 * @param seen {list of Seen} the requests
 * @return {list of string} the lines
 */
func lines(backend as string, seen as list of Seen) {
    def out as list of string init [$backend];
    for (def s in $seen) {
        def line as string init $s.method + " " + $s.path;
        if ($s.query != "") {
            $line = $line + "?" + $s.query;
        }
        $out[] = $line;
    }
    return $out;
}

/**
 * Check the requests a backend sent.
 *
 * @param backend {string} the backend
 * @param seen {list of Seen} the requests
 * @param want {list of string} the `METHOD path?query` lines expected
 */
func expect(backend as string, seen as list of Seen, want as list of string) {
    testing.assertEqual(lines($backend, $seen), lists.concat([$backend], $want));
}

/**
 * JSON text in canonical form, to compare request bodies.
 *
 * @param text {string} the JSON
 * @return {string} the canonical text
 */
func canon(text as string) {
    return json.encodeWith(json.decode($text), json.EncodeOptions{canonical: true});
}

/**
 * Check a request's JSON body.
 *
 * @param s {Seen} the request
 * @param want {string} the JSON expected
 */
func expectBody(s as Seen, want as string) {
    testing.assertEqual(canon($s.body), canon($want));
}

/**
 * Fail a test whose call was meant to throw.
 */
func missed() {
    throw Error{kind: "test", message: "the call did not fail"};
}

def const REPO_GH as string init '{"id":7,"owner":{"login":"me"},"name":"app",' +
    '"full_name":"me/app","description":"An app","private":true,"fork":false,' +
    '"archived":false,"default_branch":"main","html_url":"https://forge.test/me/app",' +
    '"clone_url":"https://forge.test/me/app.git","ssh_url":"git@forge.test:me/app.git",' +
    '"stargazers_count":3,"open_issues_count":2,"updated_at":"2026-11-03T10:00:00Z"}';

def const REPO_GL as string init '{"id":7,"name":"App","path":"app",' +
    '"path_with_namespace":"me/app","namespace":{"full_path":"me"},"description":"An app",' +
    '"visibility":"internal","archived":false,"default_branch":"main",' +
    '"web_url":"https://forge.test/me/app","http_url_to_repo":"https://forge.test/me/app.git",' +
    '"ssh_url_to_repo":"git@forge.test:me/app.git","star_count":3,"forks_count":0,' +
    '"open_issues_count":2,"last_activity_at":"2026-11-03T10:00:00Z"}';

def const REPO_FJ as string init '{"id":7,"owner":{"login":"me"},"name":"app",' +
    '"full_name":"me/app","description":"An app","private":true,"fork":false,' +
    '"archived":false,"default_branch":"main","html_url":"https://forge.test/me/app",' +
    '"clone_url":"https://forge.test/me/app.git","ssh_url":"git@forge.test:me/app.git",' +
    '"stars_count":3,"open_issues_count":2,"updated_at":"2026-11-03T10:00:00Z"}';

def const WANT_REPO as Repository init Repository{
    fullName: "me/app",
    owner: "me",
    name: "app",
    description: "An app",
    isPrivate: true,
    isFork: false,
    isArchived: false,
    defaultBranch: "main",
    htmlUrl: "https://forge.test/me/app",
    cloneUrl: "https://forge.test/me/app.git",
    sshUrl: "git@forge.test:me/app.git",
    stars: 3,
    openIssues: 2,
    updated: "2026-11-03T10:00:00Z"
};

def const ISSUE_GH as string init '{"number":12,"title":"Crash on start","body":"It crashes.",' +
    '"state":"open","user":{"login":"ada"},"labels":[{"name":"bug"},{"name":"p1"}],' +
    '"assignees":[{"login":"bob"}],"comments":1,"created_at":"2026-11-01T09:00:00Z",' +
    '"updated_at":"2026-11-02T09:00:00Z","closed_at":null,' +
    '"html_url":"https://forge.test/me/app/issues/12"}';

def const ISSUE_GL as string init '{"iid":12,"id":900,"title":"Crash on start",' +
    '"description":"It crashes.","state":"opened","author":{"username":"ada"},' +
    '"labels":["bug","p1"],"assignees":[{"username":"bob"}],"user_notes_count":1,' +
    '"created_at":"2026-11-01T09:00:00Z","updated_at":"2026-11-02T09:00:00Z",' +
    '"closed_at":null,"web_url":"https://forge.test/me/app/issues/12"}';

def const ISSUE_FJ as string init ISSUE_GH;

def const WANT_ISSUE as Issue init Issue{
    number: 12,
    title: "Crash on start",
    body: "It crashes.",
    state: "open",
    author: "ada",
    labels: ["bug", "p1"],
    assignees: ["bob"],
    comments: 1,
    isChangeRequest: false,
    created: "2026-11-01T09:00:00Z",
    updated: "2026-11-02T09:00:00Z",
    closed: "",
    htmlUrl: "https://forge.test/me/app/issues/12"
};

def const COMMENT_GH as string init '{"id":5,"user":{"login":"bob"},"body":"Same here.",' +
    '"created_at":"2026-11-02T10:00:00Z","html_url":"https://forge.test/me/app/issues/12#c5"}';

def const NOTE_GL as string init '{"id":5,"author":{"username":"bob"},"body":"Same here.",' +
    '"system":false,"created_at":"2026-11-02T10:00:00Z","updated_at":"2026-11-02T10:00:00Z"}';

def const SYSTEM_NOTE_GL as string init '{"id":4,"author":{"username":"ada"},' +
    '"body":"added ~1 label","system":true,"created_at":"2026-11-02T09:30:00Z"}';

def const WANT_COMMENT as Comment init Comment{
    id: 5,
    author: "bob",
    body: "Same here.",
    created: "2026-11-02T10:00:00Z"
};

def const PULL_GH as string init '{"number":3,"title":"Fix crash","body":"Fixes #12.",' +
    '"state":"open","user":{"login":"ada"},"head":{"ref":"fix","sha":"abc123",' +
    '"repo":{"full_name":"me/app"}},"base":{"ref":"main","repo":{"full_name":"me/app"}},' +
    '"draft":false,"mergeable":true,"merged":false,"merge_commit_sha":"7e57",' +
    '"html_url":"https://forge.test/me/app/pull/3"}';

def const MERGE_GL as string init '{"iid":3,"id":800,"title":"Fix crash",' +
    '"description":"Fixes #12.","state":"opened","author":{"username":"ada"},' +
    '"source_branch":"fix","target_branch":"main","sha":"abc123","draft":false,' +
    '"detailed_merge_status":"mergeable","merge_commit_sha":null,"squash_commit_sha":null,' +
    '"source_project_id":7,"target_project_id":7,' +
    '"web_url":"https://forge.test/me/app/pull/3","created_at":"2026-11-02T11:00:00Z"}';

def const PULL_FJ as string init '{"number":3,"title":"Fix crash","body":"Fixes #12.",' +
    '"state":"open","user":{"login":"ada"},"head":{"ref":"fix","sha":"abc123",' +
    '"repo":{"full_name":"me/app"}},"base":{"ref":"main","repo":{"full_name":"Me/App"}},' +
    '"mergeable":true,"merged":false,"merge_commit_sha":null,' +
    '"html_url":"https://forge.test/me/app/pull/3"}';

def const WANT_CHANGE as ChangeRequest init ChangeRequest{
    number: 3,
    title: "Fix crash",
    body: "Fixes #12.",
    state: "open",
    author: "ada",
    head: "fix",
    base: "main",
    headSha: "abc123",
    isDraft: false,
    mergeable: true,
    mergeSha: "",
    htmlUrl: "https://forge.test/me/app/pull/3"
};

# Three pull requests as GitHub and Forgejo list them for `closed`, merged
# and closed ones mixed.
def const CLOSED_PULLS as string init '[{"number":2,"state":"closed","merged":true,' +
    '"merged_at":"2026-11-01T00:00:00Z","merge_commit_sha":"m2","head":{"ref":"a"},' +
    '"base":{"ref":"main"}},{"number":1,"state":"closed","merged":false,"merged_at":null,' +
    '"merge_commit_sha":"t1","head":{"ref":"b"},"base":{"ref":"main"}}]';

def const RELEASE_GH as string init '{"id":40,"tag_name":"1.2.0","name":"One two",' +
    '"body":"Notes","draft":false,"prerelease":false,"created_at":"2026-11-04T08:00:00Z",' +
    '"published_at":"2026-11-04T09:00:00Z","html_url":"https://forge.test/me/app/releases/1.2.0",' +
    '"assets":[{"id":41,"name":"app.tar.gz","content_type":"application/gzip","size":10,' +
    '"download_count":2,"browser_download_url":"https://forge.test/dl/app.tar.gz",' +
    '"url":"BASE/api/v3/repos/me/app/releases/assets/41"}]}';

def const RELEASE_GL as string init '{"tag_name":"1.2.0","name":"One two",' +
    '"description":"Notes","author":{"username":"ada"},"commit":{"id":"c0ffee"},' +
    '"created_at":"2026-11-04T08:00:00Z","released_at":"2026-11-04T09:00:00Z",' +
    '"upcoming_release":false,"_links":{"self":"https://forge.test/me/app/releases/1.2.0"},' +
    '"assets":{"links":[{"id":41,"name":"app.tar.gz",' +
    '"url":"BASE/api/v4/projects/me%2Fapp/packages/generic/app/1.2.0/app.tar.gz",' +
    '"direct_asset_url":"https://forge.test/dl/app.tar.gz","link_type":"package"}],' +
    '"sources":[]}}';

def const RELEASE_FJ as string init '{"id":40,"tag_name":"1.2.0","name":"One two",' +
    '"body":"Notes","draft":false,"prerelease":false,"created_at":"2026-11-04T08:00:00Z",' +
    '"published_at":"2026-11-04T09:00:00Z","html_url":"https://forge.test/me/app/releases/1.2.0",' +
    '"assets":[{"id":41,"name":"app.tar.gz","size":10,"download_count":2,' +
    '"browser_download_url":"BASE/attachments/a1"}]}';

def const LINK_GL as string init '{"id":41,"name":"app.tar.gz",' +
    '"url":"BASE/api/v4/projects/me%2Fapp/packages/generic/app/1.2.0/app.tar.gz",' +
    '"direct_asset_url":"https://forge.test/dl/app.tar.gz","link_type":"package"}';

def const SHA as string init "0123456789abcdef0123456789abcdef01234567";
def const TREE as string init "fedcba9876543210fedcba9876543210fedcba98";

/**
 * The release every backend's reply normalises to, its asset as that
 * backend has it.
 *
 * @param backend {string} the backend
 * @param base {string} the fake server's URL
 * @return {Release} the release
 */
func wantRelease(backend as string, base as string) {
    def r as Release init Release{
        id: 40,
        tag: "1.2.0",
        name: "One two",
        body: "Notes",
        isDraft: false,
        isPrerelease: false,
        created: "2026-11-04T08:00:00Z",
        published: "2026-11-04T09:00:00Z",
        htmlUrl: "https://forge.test/me/app/releases/1.2.0",
        assets: [wantAsset($backend, $base)]
    };
    if ($backend == "gitlab") {
        $r.id = 0;
    }
    return $r;
}

/**
 * The release asset as a backend's reply normalises it.
 *
 * @param backend {string} the backend
 * @param base {string} the fake server's URL
 * @return {Asset} the asset
 */
func wantAsset(backend as string, base as string) {
    match ($backend) {
        when "github" {
            return Asset{
                id: 41,
                name: "app.tar.gz",
                contentType: "application/gzip",
                size: 10,
                downloads: 2,
                downloadUrl: "https://forge.test/dl/app.tar.gz",
                apiUrl: $base + "/api/v3/repos/me/app/releases/assets/41"
            };
        }
        when "gitlab" {
            return Asset{
                id: 41,
                name: "app.tar.gz",
                contentType: "",
                size: 0,
                downloads: 0,
                downloadUrl: "https://forge.test/dl/app.tar.gz",
                apiUrl: $base + "/api/v4/projects/me%2Fapp/packages/generic/app/1.2.0/app.tar.gz"
            };
        }
    }
    return Asset{
        id: 41,
        name: "app.tar.gz",
        contentType: "",
        size: 10,
        downloads: 2,
        downloadUrl: $base + "/attachments/a1",
        apiUrl: $base + "/attachments/a1"
    };
}

# --- constructors and repositories ------------------------------------------

func testConstructorsSetTheBackend() {
    def f as Forge init fromGithub(github.client("github.com"));
    testing.assertEqual($f.backend, "github");
    testing.assertEqual($f.github.url, "https://api.github.com");
    $f = fromGitlab(gitlab.client("gitlab.com"));
    testing.assertEqual($f.backend, "gitlab");
    testing.assertEqual($f.gitlab.url, "https://gitlab.com");
    $f = fromForgejo(forgejo.client("codeberg.org"));
    testing.assertEqual($f.backend, "forgejo");
    testing.assertEqual($f.forgejo.url, "https://codeberg.org");
    testing.assertEqual(BACKENDS, ["github", "gitlab", "forgejo"]);
}

func testConnect() {
    def f as Forge init connect("github", "github.com", "t0k3n");
    testing.assertEqual($f.backend, "github");
    testing.assertEqual($f.github.url, "https://api.github.com");
    testing.assertEqual($f.github.token, "t0k3n");
    $f = connect("gitlab", "gitlab.example.org", "glpat-x");
    testing.assertEqual($f.backend, "gitlab");
    testing.assertEqual($f.gitlab.url, "https://gitlab.example.org");
    testing.assertEqual($f.gitlab.token, "glpat-x");
    $f = connect("forgejo", "codeberg.org", "");
    testing.assertEqual($f.backend, "forgejo");
    testing.assertEqual($f.forgejo.url, "https://codeberg.org");
    testing.assertEqual($f.forgejo.token, "");
    # a Forge from connect works like one from fromForgejo
    def fk as Fake init fake([ok(REPO_FJ)]);
    testing.assertEqual(repository(connect("forgejo", $fk.url, "t0k3n"), "me/app").name, "app");
    finish($fk);
    for (def bad in [["svn", "x"], ["GitHub", "x"], ["", "x"]]) {
        try {
            connect($bad[0], "github.com", "");
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.backend, "");
            testing.assertContains($e.message, "a backend is one of github, gitlab, forgejo");
        }
    }
    # the backend deck's own checks, as a CodehostError of that backend
    for (def b in BACKENDS) {
        try {
            connect($b, "example.org", "has space");
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.backend, $b);
            testing.assertContains($e.message, "token");
        }
    }
}

func testRepository() {
    for (def b in BACKENDS) {
        def body as string init REPO_GH;
        def want as list of string init ["GET /api/v3/repos/me/app"];
        if ($b == "gitlab") {
            $body = REPO_GL;
            $want = ["GET /api/v4/projects/me/app"];
        } elseif ($b == "forgejo") {
            $body = REPO_FJ;
            $want = ["GET /api/v1/repos/me/app"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(repository(forgeOn($b, $fk), "me/app"), WANT_REPO);
        expect($b, finish($fk), $want);
    }
}

func testMyRepositories() {
    for (def b in BACKENDS) {
        def body as string init "[" + REPO_GH + "]";
        def want as list of string init ["GET /api/v3/user/repos?per_page=100"];
        if ($b == "gitlab") {
            $body = "[" + REPO_GL + "]";
            $want = ["GET /api/v4/projects?membership=true&per_page=100"];
        } elseif ($b == "forgejo") {
            $body = "[" + REPO_FJ + "]";
            $want = ["GET /api/v1/user/repos?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(myRepositories(forgeOn($b, $fk)), [WANT_REPO]);
        expect($b, finish($fk), $want);
    }
}

func testGitlabRepositoryFields() {
    def p as gitlab.Project;
    $p.fullPath = "grp/sub/app";
    $p.namespace = "grp/sub";
    $p.path = "app";
    $p.name = "The App";
    $p.visibility = "public";
    $p.forkedFrom = "other/app";
    def r as Repository init gitlabRepository($p);
    testing.assertEqual($r.fullName, "grp/sub/app");
    testing.assertEqual($r.owner, "grp/sub");
    testing.assertEqual($r.name, "app");
    testing.assertFalse($r.isPrivate);
    testing.assertTrue($r.isFork);
}

# --- issues -----------------------------------------------------------------

func testIssues() {
    for (def b in BACKENDS) {
        # GitHub's listing mixes pull requests in; the github deck drops them.
        def body as string init "[" + ISSUE_GH + ',{"number":3,"pull_request":{}}]';
        def want as list of string init ["GET /api/v3/repos/me/app/issues?state=open&per_page=100"];
        if ($b == "gitlab") {
            $body = "[" + ISSUE_GL + "]";
            $want = ["GET /api/v4/projects/me/app/issues?state=opened&per_page=100"];
        } elseif ($b == "forgejo") {
            $body = "[" + ISSUE_FJ + "]";
            $want = ["GET /api/v1/repos/me/app/issues?type=issues&state=open&limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(issues(forgeOn($b, $fk), "me/app", "open"), [WANT_ISSUE]);
        expect($b, finish($fk), $want);
    }
}

func testIssue() {
    for (def b in BACKENDS) {
        def body as string init ISSUE_GH;
        def want as list of string init ["GET /api/v3/repos/me/app/issues/12"];
        if ($b == "gitlab") {
            $body = ISSUE_GL;
            $want = ["GET /api/v4/projects/me/app/issues/12"];
        } elseif ($b == "forgejo") {
            $body = ISSUE_FJ;
            $want = ["GET /api/v1/repos/me/app/issues/12"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(issue(forgeOn($b, $fk), "me/app", 12), WANT_ISSUE);
        expect($b, finish($fk), $want);
    }
}

func testIssueOfAPullRequest() {
    def fk as Fake init fake([ok('{"number":3,"state":"open","pull_request":{"url":"x"}}')]);
    testing.assertTrue(issue(forgeOn("github", $fk), "me/app", 3).isChangeRequest);
    finish($fk);
}

func testCreateIssue() {
    for (def b in BACKENDS) {
        def body as string init ISSUE_GH;
        def want as list of string init ["POST /api/v3/repos/me/app/issues"];
        def sent as string init '{"title":"Crash on start","body":"It crashes."}';
        if ($b == "gitlab") {
            $body = ISSUE_GL;
            $want = ["POST /api/v4/projects/me/app/issues"];
            $sent = '{"title":"Crash on start","description":"It crashes."}';
        } elseif ($b == "forgejo") {
            $body = ISSUE_FJ;
            $want = ["POST /api/v1/repos/me/app/issues"];
        }
        def fk as Fake init fake([answer(201, $body)]);
        testing.assertEqual(
            createIssue(forgeOn($b, $fk), "me/app", "Crash on start", "It crashes."),
            WANT_ISSUE);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], $sent);
    }
}

func testCloseAndReopenIssue() {
    for (def b in BACKENDS) {
        def closed as string init strings.replace(ISSUE_GH, '"state":"open"', '"state":"closed"');
        def body as string init ISSUE_GH;
        def want as list of string init [
            "PATCH /api/v3/repos/me/app/issues/12",
            "PATCH /api/v3/repos/me/app/issues/12"
        ];
        def sent as list of string init ['{"state":"closed"}', '{"state":"open"}'];
        if ($b == "gitlab") {
            $closed = strings.replace(ISSUE_GL, '"state":"opened"', '"state":"closed"');
            $body = ISSUE_GL;
            $want = [
                "PUT /api/v4/projects/me/app/issues/12",
                "PUT /api/v4/projects/me/app/issues/12"
            ];
            $sent = ['{"state_event":"close"}', '{"state_event":"reopen"}'];
        } elseif ($b == "forgejo") {
            $want = [
                "PATCH /api/v1/repos/me/app/issues/12",
                "PATCH /api/v1/repos/me/app/issues/12"
            ];
        }
        def fk as Fake init fake([ok($closed), ok($body)]);
        def f as Forge init forgeOn($b, $fk);
        testing.assertEqual(closeIssue($f, "me/app", 12).state, "closed");
        testing.assertEqual(reopenIssue($f, "me/app", 12), WANT_ISSUE);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], $sent[0]);
        expectBody($seen[1], $sent[1]);
    }
}

func testIssueStatesAreChecked() {
    def f as Forge init fromGitlab(gitlab.client("gitlab.test"));
    try {
        issues($f, "me/app", "opened");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
        testing.assertEqual($e.backend, "gitlab");
        testing.assertContains($e.message, "open, closed or all");
    }
}

# --- comments ---------------------------------------------------------------

func testComments() {
    for (def b in BACKENDS) {
        def body as string init "[" + COMMENT_GH + "]";
        def want as list of string init [
            "GET /api/v3/repos/me/app/issues/12/comments?per_page=100"
        ];
        if ($b == "gitlab") {
            $body = "[" + SYSTEM_NOTE_GL + "," + NOTE_GL + "]";
            $want = [
                "GET /api/v4/projects/me/app/issues/12/notes?sort=asc&order_by=created_at&per_page=100"
            ];
        } elseif ($b == "forgejo") {
            $want = ["GET /api/v1/repos/me/app/issues/12/comments?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(comments(forgeOn($b, $fk), "me/app", 12), [WANT_COMMENT]);
        expect($b, finish($fk), $want);
    }
}

func testComment() {
    for (def b in BACKENDS) {
        def body as string init COMMENT_GH;
        def want as list of string init ["POST /api/v3/repos/me/app/issues/12/comments"];
        if ($b == "gitlab") {
            $body = NOTE_GL;
            $want = ["POST /api/v4/projects/me/app/issues/12/notes"];
        } elseif ($b == "forgejo") {
            $want = ["POST /api/v1/repos/me/app/issues/12/comments"];
        }
        def fk as Fake init fake([answer(201, $body)]);
        testing.assertEqual(comment(forgeOn($b, $fk), "me/app", 12, "Same here."), WANT_COMMENT);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], '{"body":"Same here."}');
    }
}

# --- labels -----------------------------------------------------------------

func testLabels() {
    for (def b in BACKENDS) {
        def body as string init '[{"id":1,"name":"bug","color":"d73a4a",' +
            '"description":"Something is wrong","default":true}]';
        def want as list of string init ["GET /api/v3/repos/me/app/labels?per_page=100"];
        if ($b == "gitlab") {
            $body = '[{"id":1,"name":"bug","color":"#d73a4a","description":"Something is wrong"}]';
            $want = ["GET /api/v4/projects/me/app/labels?per_page=100"];
        } elseif ($b == "forgejo") {
            $want = ["GET /api/v1/repos/me/app/labels?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(
            labels(forgeOn($b, $fk), "me/app"),
            [Label{name: "bug", color: "#d73a4a", description: "Something is wrong"}]);
        expect($b, finish($fk), $want);
    }
}

func testCreateLabel() {
    for (def b in BACKENDS) {
        def body as string init '{"id":2,"name":"ui","color":"00ff00","description":"Looks"}';
        def want as list of string init ["POST /api/v3/repos/me/app/labels"];
        def sent as string init '{"name":"ui","color":"00ff00","description":"Looks"}';
        if ($b == "gitlab") {
            $body = '{"id":2,"name":"ui","color":"#00ff00","description":"Looks"}';
            $want = ["POST /api/v4/projects/me/app/labels"];
            $sent = '{"name":"ui","color":"#00ff00","description":"Looks"}';
        } elseif ($b == "forgejo") {
            $want = ["POST /api/v1/repos/me/app/labels"];
            $sent = '{"name":"ui","color":"#00ff00","description":"Looks"}';
        }
        def fk as Fake init fake([answer(201, $body)]);
        testing.assertEqual(
            createLabel(forgeOn($b, $fk), "me/app", "ui", "#00ff00", "Looks"),
            Label{name: "ui", color: "#00ff00", description: "Looks"});
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], $sent);
    }
}

func testSetIssueLabels() {
    for (def b in BACKENDS) {
        def labelled as string init '[{"id":1,"name":"bug"},{"id":2,"name":"new"}]';
        def replies as list of Reply init [ok($labelled)];
        def want as list of string init ["PUT /api/v3/repos/me/app/issues/12/labels"];
        def sent as string init '{"labels":["bug","new"]}';
        if ($b == "gitlab") {
            $replies = [ok(strings.replace(ISSUE_GL, '["bug","p1"]', '["bug","new"]'))];
            $want = ["PUT /api/v4/projects/me/app/issues/12"];
            $sent = '{"labels":"bug,new"}';
        } elseif ($b == "forgejo") {
            # Forgejo drops a name it has no label for: the deck makes it and
            # adds it.
            $replies = [
                ok('[{"id":1,"name":"bug","color":"d73a4a"}]'),
                ok('[{"id":1,"name":"bug","color":"d73a4a"}]'),
                answer(201, '{"id":2,"name":"new","color":"ededed"}'),
                ok($labelled)
            ];
            $want = [
                "PUT /api/v1/repos/me/app/issues/12/labels",
                "GET /api/v1/repos/me/app/labels?limit=50&page=1",
                "POST /api/v1/repos/me/app/labels",
                "POST /api/v1/repos/me/app/issues/12/labels"
            ];
            $sent = '{"labels":["new"]}';
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            setIssueLabels(forgeOn($b, $fk), "me/app", 12, ["bug", "new"]),
            ["bug", "new"]);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[len($seen) - 1], $sent);
        if ($b == "forgejo") {
            expectBody($seen[0], '{"labels":["bug","new"]}');
            expectBody($seen[2], '{"name":"new","color":"#ededed"}');
        }
    }
}

func testForgejoOrganizationLabelsAreNotMadeAgain() {
    # `bug` is a label of the repository's organization: Forgejo takes it
    # by name, and a repository label of the same name would label the issue
    # twice.
    def fk as Fake init fake([ok('[{"id":1,"name":"bug","color":"ee0701"}]')]);
    def f as Forge init forgeOn("forgejo", $fk);
    $f.forgejo = forgejo.withTimeout($f.forgejo, 1000);
    testing.assertEqual(setIssueLabels($f, "acme/app", 12, ["bug"]), ["bug"]);
    expect("forgejo", finish($fk), ["PUT /api/v1/repos/acme/app/issues/12/labels"]);
}

func testForgejoLabelNamesAreChecked() {
    def fk as Fake init fake([]);
    try {
        setIssueLabels(forgeOn("forgejo", $fk), "me/app", 12, ["bug", " "]);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
    }
    testing.assertEqual(len(finish($fk)), 0);
}

func testAddIssueLabels() {
    for (def b in BACKENDS) {
        def labelled as string init '[{"id":1,"name":"bug"},{"id":2,"name":"new"}]';
        def replies as list of Reply init [ok($labelled)];
        def want as list of string init ["POST /api/v3/repos/me/app/issues/12/labels"];
        def sent as string init '{"labels":["new"]}';
        if ($b == "gitlab") {
            $replies = [ok(strings.replace(ISSUE_GL, '["bug","p1"]', '["bug","new"]'))];
            $want = ["PUT /api/v4/projects/me/app/issues/12"];
            $sent = '{"add_labels":"new"}';
        } elseif ($b == "forgejo") {
            # every name exists already: nothing is listed or created
            $want = ["POST /api/v1/repos/me/app/issues/12/labels"];
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            addIssueLabels(forgeOn($b, $fk), "me/app", 12, ["new"]),
            ["bug", "new"]);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[len($seen) - 1], $sent);
    }
}

func testAddIssueLabelsNeedsAName() {
    try {
        addIssueLabels(fromGithub(github.client("github.com")), "me/app", 12, []);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.backend, "github");
    }
}

func testRemoveIssueLabel() {
    for (def b in BACKENDS) {
        def replies as list of Reply init [ok('[]')];
        def want as list of string init [
            "DELETE /api/v3/repos/me/app/issues/12/labels/needs triage"
        ];
        if ($b == "gitlab") {
            $replies = [ok(ISSUE_GL)];
            $want = ["PUT /api/v4/projects/me/app/issues/12"];
        } elseif ($b == "forgejo") {
            # Gitea takes the label's id only: the issue's labels name it
            $replies = [
                ok('[{"id":9,"name":"bug"},{"id":7,"name":"needs triage"}]'),
                answer(204, "")
            ];
            $want = [
                "GET /api/v1/repos/me/app/issues/12/labels?limit=50&page=1",
                "DELETE /api/v1/repos/me/app/issues/12/labels/7"
            ];
        }
        def fk as Fake init fake($replies);
        removeIssueLabel(forgeOn($b, $fk), "me/app", 12, "needs triage");
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        if ($b == "gitlab") {
            expectBody($seen[0], '{"remove_labels":"needs triage"}');
        }
    }
}

func testForgejoRemovesALabelItLacksWithoutAWord() {
    def fk as Fake init fake([ok('[{"id":9,"name":"bug"}]')]);
    removeIssueLabel(forgeOn("forgejo", $fk), "me/app", 12, "needs triage");
    expect("forgejo", finish($fk), ["GET /api/v1/repos/me/app/issues/12/labels?limit=50&page=1"]);
}

func testLabelColoursAreLowerCase() {
    def fk as Fake init fake([ok('[{"id":1,"name":"ui","color":"#00FF00","description":""}]')]);
    testing.assertEqual(
        labels(forgeOn("gitlab", $fk), "me/app"),
        [Label{name: "ui", color: "#00ff00", description: ""}]);
    finish($fk);
}

# --- change requests --------------------------------------------------------

func testChangeRequests() {
    for (def b in BACKENDS) {
        def body as string init "[" + PULL_GH + "]";
        def want as list of string init ["GET /api/v3/repos/me/app/pulls?state=open&per_page=100"];
        if ($b == "gitlab") {
            $body = "[" + MERGE_GL + "]";
            $want = ["GET /api/v4/projects/me/app/merge_requests?state=opened&per_page=100"];
        } elseif ($b == "forgejo") {
            $body = "[" + PULL_FJ + "]";
            $want = ["GET /api/v1/repos/me/app/pulls?state=open&limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(changeRequests(forgeOn($b, $fk), "me/app", "open"), [WANT_CHANGE]);
        expect($b, finish($fk), $want);
    }
}

func testMergedAndClosedAreApart() {
    for (def b in BACKENDS) {
        def mergedBody as string init CLOSED_PULLS;
        def closedBody as string init CLOSED_PULLS;
        def want as list of string init [
            "GET /api/v3/repos/me/app/pulls?state=closed&per_page=100",
            "GET /api/v3/repos/me/app/pulls?state=closed&per_page=100"
        ];
        if ($b == "gitlab") {
            $mergedBody = '[{"iid":2,"state":"merged","merge_commit_sha":"m2","sha":"h2"}]';
            $closedBody = '[{"iid":1,"state":"closed","merge_commit_sha":null,"sha":"h1"}]';
            $want = [
                "GET /api/v4/projects/me/app/merge_requests?state=merged&per_page=100",
                "GET /api/v4/projects/me/app/merge_requests?state=closed&per_page=100"
            ];
        } elseif ($b == "forgejo") {
            $want = [
                "GET /api/v1/repos/me/app/pulls?state=closed&limit=50&page=1",
                "GET /api/v1/repos/me/app/pulls?state=closed&limit=50&page=1"
            ];
        }
        def fk as Fake init fake([ok($mergedBody), ok($closedBody)]);
        def f as Forge init forgeOn($b, $fk);
        def merged as list of ChangeRequest init changeRequests($f, "me/app", "merged");
        def closed as list of ChangeRequest init changeRequests($f, "me/app", "closed");
        testing.assertEqual(len($merged), 1);
        testing.assertEqual($merged[0].number, 2);
        testing.assertEqual($merged[0].state, "merged");
        testing.assertEqual($merged[0].mergeSha, "m2");
        testing.assertEqual(len($closed), 1);
        testing.assertEqual($closed[0].number, 1);
        testing.assertEqual($closed[0].state, "closed");
        testing.assertEqual($closed[0].mergeSha, "");
        expect($b, finish($fk), $want);
    }
}

func testChangeRequest() {
    for (def b in BACKENDS) {
        def body as string init PULL_GH;
        def want as list of string init ["GET /api/v3/repos/me/app/pulls/3"];
        if ($b == "gitlab") {
            $body = MERGE_GL;
            $want = ["GET /api/v4/projects/me/app/merge_requests/3"];
        } elseif ($b == "forgejo") {
            $body = PULL_FJ;
            $want = ["GET /api/v1/repos/me/app/pulls/3"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(changeRequest(forgeOn($b, $fk), "me/app", 3), WANT_CHANGE);
        expect($b, finish($fk), $want);
    }
}

func testGitlabStatesAndMergeCommits() {
    def m as gitlab.MergeRequest;
    $m.state = "locked";
    testing.assertEqual(gitlabChange($m).state, "open");
    $m.state = "merged";
    $m.merged = true;
    $m.sha = "head";
    testing.assertEqual(gitlabChange($m).mergeSha, "head");
    $m.squashSha = "squashed";
    testing.assertEqual(gitlabChange($m).mergeSha, "squashed");
    $m.mergeSha = "merge";
    testing.assertEqual(gitlabChange($m).mergeSha, "merge");
}

func testCreateChangeRequest() {
    for (def b in BACKENDS) {
        def body as string init PULL_GH;
        def want as list of string init ["POST /api/v3/repos/me/app/pulls"];
        def sent as string init '{"head":"fix","base":"main","title":"Fix crash","body":"Fixes #12."}';
        if ($b == "gitlab") {
            $body = MERGE_GL;
            $want = ["POST /api/v4/projects/me/app/merge_requests"];
            $sent = '{"source_branch":"fix","target_branch":"main","title":"Fix crash",' +
                '"description":"Fixes #12."}';
        } elseif ($b == "forgejo") {
            $body = PULL_FJ;
            $want = ["POST /api/v1/repos/me/app/pulls"];
        }
        def fk as Fake init fake([answer(201, $body)]);
        testing.assertEqual(
            createChangeRequest(
                forgeOn($b, $fk),
                "me/app",
                "fix",
                "main",
                "Fix crash",
                "Fixes #12.",
                false),
            WANT_CHANGE);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], $sent);
    }
}

func testCreateDraftChangeRequest() {
    def draft as ChangeRequest init WANT_CHANGE;
    $draft.isDraft = true;
    $draft.mergeable = false;
    for (def b in BACKENDS) {
        def replies as list of Reply init [
            answer(201, '{"number":3}'),
            ok(strings.replace(PULL_GH, '"draft":false', '"draft":true'))
        ];
        def want as list of string init [
            "POST /api/v3/repos/me/app/pulls",
            "GET /api/v3/repos/me/app/pulls/3"
        ];
        def sent as string init '{"head":"fix","base":"main","title":"Fix crash",' +
            '"body":"Fixes #12.","draft":true}';
        if ($b == "gitlab") {
            def made as string init strings.replace(MERGE_GL, '"draft":false', '"draft":true');
            $replies = [answer(201, strings.replace($made, '"Fix crash"', '"Draft: Fix crash"'))];
            $want = ["POST /api/v4/projects/me/app/merge_requests"];
            $sent = '{"source_branch":"fix","target_branch":"main","title":"Draft: Fix crash",' +
                '"description":"Fixes #12."}';
        } elseif ($b == "forgejo") {
            # no `draft` member: the title alone marks it
            $replies = [answer(201, strings.replace(PULL_FJ, '"Fix crash"', '"WIP: Fix crash"'))];
            $want = ["POST /api/v1/repos/me/app/pulls"];
            $sent = '{"head":"fix","base":"main","title":"WIP: Fix crash","body":"Fixes #12."}';
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            createChangeRequest(
                forgeOn($b, $fk),
                "me/app",
                "fix",
                "main",
                "Fix crash",
                "Fixes #12.",
                true),
            $draft);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], $sent);
    }
}

func testDraftPrefixes() {
    testing.assertEqual(undrafted(DRAFT_PREFIX, "Draft: Fix"), "Fix");
    testing.assertEqual(undrafted(DRAFT_PREFIX, "[WIP] Fix"), "Fix");
    testing.assertEqual(undrafted(DRAFT_PREFIX, "(draft) Fix"), "Fix");
    testing.assertEqual(undrafted(DRAFT_PREFIX, "wip:Fix"), "Fix");
    testing.assertEqual(undrafted(DRAFT_PREFIX, "Drafting: Fix"), "Drafting: Fix");
    testing.assertEqual(undrafted(GITLAB_DRAFT, "draft:[Draft] Fix"), "Fix");
    testing.assertEqual(undrafted(GITLAB_DRAFT, "WIP: Fix"), "WIP: Fix");
}

func testDraftsUseTheForgesOwnPrefix() {
    # GitLab 19 reads only Draft:, [Draft], (Draft); Forgejo and Gitea only
    # WIP:, [WIP] (both checked live): a title with the other forge's prefix
    # still gets this forge's, one with its own is left alone
    def cases as list of list of string init [
        ["gitlab", "WIP: Fix", "Draft: WIP: Fix"],
        ["gitlab", "[Draft] Fix", "[Draft] Fix"],
        ["forgejo", "Draft: Fix", "WIP: Draft: Fix"],
        ["forgejo", "[wip] Fix", "[wip] Fix"]
    ];
    for (def c in $cases) {
        def body as string init MERGE_GL;
        if ($c[0] == "forgejo") {
            $body = PULL_FJ;
        }
        def fk as Fake init fake([answer(201, $body)]);
        createChangeRequest(forgeOn($c[0], $fk), "me/app", "fix", "main", $c[1], "", true);
        def seen as list of Seen init finish($fk);
        testing.assertEqual(
            [$c[0], json.asString(json.decode($seen[0].body), "/title")],
            [$c[0], $c[2]]);
    }
}

# A title the forge itself reads as a draft contradicts isDraft false: refused
# before any request. Another forge's prefix is ordinary text.
func testDraftPrefixWithoutIsDraftIsRefused() {
    for (def c in [
        ["gitlab", "Draft: Fix"],
        ["gitlab", "[draft] Fix"],
        ["gitlab", "(Draft)Fix"],
        ["forgejo", "WIP: Fix"],
        ["forgejo", "[Wip] Fix"]
    ]) {
        # no fake behind it: a request would be a connection error instead
        def fk as Fake init fake([]);
        def f as Forge init forgeOn($c[0], $fk);
        finish($fk);
        try {
            createChangeRequest($f, "me/app", "fix", "main", $c[1], "", false);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.status, 0);
            testing.assertEqual($e.backend, $c[0]);
            testing.assertContains($e.message, "makes a draft on " + $c[0]);
        }
    }
    for (def c in [
        ["github", "Draft: Fix"],
        ["github", "WIP: Fix"],
        ["gitlab", "WIP: Fix"],
        ["forgejo", "Draft: Fix"]
    ]) {
        def body as string init PULL_GH;
        if ($c[0] == "gitlab") {
            $body = MERGE_GL;
        } elseif ($c[0] == "forgejo") {
            $body = PULL_FJ;
        }
        def fk as Fake init fake([answer(201, $body)]);
        createChangeRequest(forgeOn($c[0], $fk), "me/app", "fix", "main", $c[1], "", false);
        def seen as list of Seen init finish($fk);
        testing.assertEqual(
            [$c[0], json.asString(json.decode($seen[0].body), "/title")],
            [$c[0], $c[1]]);
    }
}

func testForgejoDraftIsItsMemberOrWip() {
    def p as forgejo.PullRequest;
    $p.state = "open";
    $p.mergeable = true;
    $p.title = "Draft: two";
    # not a draft to Forgejo, which merges it
    testing.assertEqual(
        [forgejoChange($p).isDraft, forgejoChange($p).title],
        [false, "Draft: two"]);
    $p.title = "[wip] three";
    testing.assertEqual([forgejoChange($p).isDraft, forgejoChange($p).title], [true, "three"]);
    $p.title = "Draft: four";
    $p.isDraft = true;
    testing.assertEqual([forgejoChange($p).isDraft, forgejoChange($p).title], [true, "four"]);
}

func testMergeableOnlyWhenOpenAndReady() {
    # GitHub answers mergeable for a draft and a closed pull request, Forgejo
    # for a merged one (seen live); none of them can be merged
    def g as github.PullRequest;
    $g.state = "open";
    $g.mergeable = true;
    testing.assertTrue(githubChange($g).mergeable);
    $g.isDraft = true;
    testing.assertFalse(githubChange($g).mergeable);
    $g.isDraft = false;
    $g.state = "closed";
    testing.assertFalse(githubChange($g).mergeable);
    def p as forgejo.PullRequest;
    $p.state = "closed";
    $p.merged = true;
    $p.mergeable = true;
    testing.assertFalse(forgejoChange($p).mergeable);
    def m as gitlab.MergeRequest;
    $m.state = "opened";
    $m.mergeable = true;
    testing.assertTrue(gitlabChange($m).mergeable);
    $m.state = "closed";
    testing.assertFalse(gitlabChange($m).mergeable);
}

func testNumbersAreChecked() {
    for (def b in BACKENDS) {
        def fk as Fake init fake([]);
        def f as Forge init forgeOn($b, $fk);
        for (def n in [0, -1]) {
            try {
                issue($f, "me/app", $n);
                missed();
            } catch (e) {
                testing.assertEqual([$b, $e.kind, $e.status], [$b, ERROR_KIND, 0]);
                testing.assertTrue(strings.startsWith($e.message, "codehost: "));
            }
            try {
                mergeChangeRequest($f, "me/app", $n, "merge", true);
                missed();
            } catch (e) {
                testing.assertEqual([$b, $e.kind, $e.status], [$b, ERROR_KIND, 0]);
            }
        }
        testing.assertEqual(len(finish($fk)), 0);
    }
}

func testCloseAndReopenChangeRequest() {
    for (def b in BACKENDS) {
        def closed as string init strings.replace(PULL_GH, '"state":"open"', '"state":"closed"');
        def replies as list of Reply init [ok(ISSUE_GH), ok($closed), ok(ISSUE_GH), ok(PULL_GH)];
        def want as list of string init [
            "PATCH /api/v3/repos/me/app/issues/3",
            "GET /api/v3/repos/me/app/pulls/3",
            "PATCH /api/v3/repos/me/app/issues/3",
            "GET /api/v3/repos/me/app/pulls/3"
        ];
        if ($b == "gitlab") {
            $replies = [
                ok(strings.replace(MERGE_GL, '"state":"opened"', '"state":"closed"')),
                ok(MERGE_GL)
            ];
            $want = [
                "PUT /api/v4/projects/me/app/merge_requests/3",
                "PUT /api/v4/projects/me/app/merge_requests/3"
            ];
        } elseif ($b == "forgejo") {
            $closed = strings.replace(PULL_FJ, '"state":"open"', '"state":"closed"');
            $replies = [ok(ISSUE_FJ), ok($closed), ok(ISSUE_FJ), ok(PULL_FJ)];
            $want = [
                "PATCH /api/v1/repos/me/app/issues/3",
                "GET /api/v1/repos/me/app/pulls/3",
                "PATCH /api/v1/repos/me/app/issues/3",
                "GET /api/v1/repos/me/app/pulls/3"
            ];
        }
        def fk as Fake init fake($replies);
        def f as Forge init forgeOn($b, $fk);
        testing.assertEqual(closeChangeRequest($f, "me/app", 3).state, "closed");
        testing.assertEqual(reopenChangeRequest($f, "me/app", 3), WANT_CHANGE);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        if ($b == "gitlab") {
            expectBody($seen[0], '{"state_event":"close"}');
        } else {
            expectBody($seen[0], '{"state":"closed"}');
        }
    }
}

func testMergeChangeRequest() {
    for (def b in BACKENDS) {
        def replies as list of Reply init [
            ok(PULL_GH),
            ok('{"merged":true,"sha":"m3"}'),
            answer(204, "")
        ];
        def want as list of string init [
            "GET /api/v3/repos/me/app/pulls/3",
            "PUT /api/v3/repos/me/app/pulls/3/merge",
            "DELETE /api/v3/repos/me/app/git/refs/heads/fix"
        ];
        def sent as string init '{"merge_method":"squash"}';
        def at as int init 1;
        if ($b == "gitlab") {
            $replies = [ok(MERGE_GL), ok(MERGE_GL)];
            $want = [
                "GET /api/v4/projects/me/app/merge_requests/3",
                "PUT /api/v4/projects/me/app/merge_requests/3/merge"
            ];
            $sent = '{"squash":true,"should_remove_source_branch":true}';
        } elseif ($b == "forgejo") {
            $replies = [ok(PULL_FJ), ok("")];
            $want = ["GET /api/v1/repos/me/app/pulls/3", "POST /api/v1/repos/me/app/pulls/3/merge"];
            $sent = '{"Do":"squash","delete_branch_after_merge":true}';
        }
        def fk as Fake init fake($replies);
        mergeChangeRequest(forgeOn($b, $fk), "me/app", 3, "squash", true);
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[$at], $sent);
    }
}

func testMergeLeavesAForksBranch() {
    for (def b in ["gitlab", "forgejo"]) {
        def replies as list of Reply init [
            ok(strings.replace(MERGE_GL, '"source_project_id":7', '"source_project_id":8')),
            ok(MERGE_GL)
        ];
        def sent as string init '{"squash":false,"should_remove_source_branch":false}';
        if ($b == "forgejo") {
            $replies = [
                ok(strings.replace(
                    PULL_FJ,
                    '"repo":{"full_name":"me/app"}',
                    '"repo":{"full_name":"you/app"}')),
                ok("")
            ];
            $sent = '{"Do":"merge","delete_branch_after_merge":false}';
        }
        def fk as Fake init fake($replies);
        mergeChangeRequest(forgeOn($b, $fk), "me/app", 3, "merge", true);
        def seen as list of Seen init finish($fk);
        expectBody($seen[1], $sent);
    }
}

func testMergeWithoutDeletingReadsNothing() {
    def fk as Fake init fake([ok(MERGE_GL)]);
    mergeChangeRequest(forgeOn("gitlab", $fk), "me/app", 3, "merge", false);
    def seen as list of Seen init finish($fk);
    expect("gitlab", $seen, ["PUT /api/v4/projects/me/app/merge_requests/3/merge"]);
    expectBody($seen[0], '{"squash":false,"should_remove_source_branch":false}');
}

func testMergeStyles() {
    testing.assertEqual(MERGE_STYLES, ["merge", "squash", "rebase"]);
    def fk as Fake init fake([]);
    try {
        mergeChangeRequest(forgeOn("gitlab", $fk), "me/app", 3, "rebase", false);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.backend, "gitlab");
        testing.assertContains($e.message, "merge method");
    }
    try {
        mergeChangeRequest(forgeOn("forgejo", $fk), "me/app", 3, "fast-forward-only", false);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
    }
    testing.assertEqual(len(finish($fk)), 0);
}

func testChangeRequestComments() {
    for (def b in BACKENDS) {
        def body as string init "[" + COMMENT_GH + "]";
        def want as list of string init ["GET /api/v3/repos/me/app/issues/3/comments?per_page=100"];
        if ($b == "gitlab") {
            $body = "[" + NOTE_GL + "," + SYSTEM_NOTE_GL + "]";
            $want = [
                "GET /api/v4/projects/me/app/merge_requests/3/notes?sort=asc&order_by=created_at&per_page=100"
            ];
        } elseif ($b == "forgejo") {
            $want = ["GET /api/v1/repos/me/app/issues/3/comments?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(changeRequestComments(forgeOn($b, $fk), "me/app", 3), [WANT_COMMENT]);
        expect($b, finish($fk), $want);
    }
}

func testCommentChangeRequest() {
    for (def b in BACKENDS) {
        def body as string init COMMENT_GH;
        def want as list of string init ["POST /api/v3/repos/me/app/issues/3/comments"];
        if ($b == "gitlab") {
            $body = NOTE_GL;
            $want = ["POST /api/v4/projects/me/app/merge_requests/3/notes"];
        } elseif ($b == "forgejo") {
            $want = ["POST /api/v1/repos/me/app/issues/3/comments"];
        }
        def fk as Fake init fake([answer(201, $body)]);
        testing.assertEqual(
            commentChangeRequest(forgeOn($b, $fk), "me/app", 3, "Same here."),
            WANT_COMMENT);
        expect($b, finish($fk), $want);
    }
}

# --- releases ---------------------------------------------------------------

func testReleases() {
    for (def b in BACKENDS) {
        def body as string init "[" + RELEASE_GH + "]";
        def want as list of string init ["GET /api/v3/repos/me/app/releases?per_page=100"];
        if ($b == "gitlab") {
            $body = "[" + RELEASE_GL + "]";
            $want = ["GET /api/v4/projects/me/app/releases?per_page=100"];
        } elseif ($b == "forgejo") {
            $body = "[" + RELEASE_FJ + "]";
            $want = ["GET /api/v1/repos/me/app/releases?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(releases(forgeOn($b, $fk), "me/app"), [wantRelease($b, $fk.url)]);
        expect($b, finish($fk), $want);
    }
}

func testReleaseAndLatest() {
    for (def b in BACKENDS) {
        def body as string init RELEASE_GH;
        def want as list of string init [
            "GET /api/v3/repos/me/app/releases/tags/1.2.0",
            "GET /api/v3/repos/me/app/releases/latest"
        ];
        if ($b == "gitlab") {
            $body = RELEASE_GL;
            $want = [
                "GET /api/v4/projects/me/app/releases/1.2.0",
                "GET /api/v4/projects/me/app/releases/permalink/latest"
            ];
        } elseif ($b == "forgejo") {
            $body = RELEASE_FJ;
            $want = [
                "GET /api/v1/repos/me/app/releases/tags/1.2.0",
                "GET /api/v1/repos/me/app/releases/latest"
            ];
        }
        def fk as Fake init fake([ok($body), ok($body)]);
        def f as Forge init forgeOn($b, $fk);
        testing.assertEqual(release($f, "me/app", "1.2.0"), wantRelease($b, $fk.url));
        testing.assertEqual(latestRelease($f, "me/app"), wantRelease($b, $fk.url));
        expect($b, finish($fk), $want);
    }
}

func testForgejoDraftReleaseIsUnpublished() {
    def r as forgejo.Release;
    $r.isDraft = true;
    $r.published = "2026-11-04T09:00:00Z";
    testing.assertEqual(forgejoRelease($r).published, "");
}

func testCreateRelease() {
    for (def b in BACKENDS) {
        def replies as list of Reply init [answer(201, RELEASE_GH)];
        def want as list of string init ["POST /api/v3/repos/me/app/releases"];
        def sent as string init '{"tag_name":"1.2.0","name":"One two","body":"Notes",' +
            '"draft":false,"prerelease":false}';
        if ($b == "gitlab") {
            # a target of "" is the default branch, which GitLab wants named
            $replies = [ok(REPO_GL), answer(201, RELEASE_GL)];
            $want = ["GET /api/v4/projects/me/app", "POST /api/v4/projects/me/app/releases"];
            $sent = '{"tag_name":"1.2.0","ref":"main","name":"One two","description":"Notes"}';
        } elseif ($b == "forgejo") {
            $replies = [answer(201, RELEASE_FJ)];
            $want = ["POST /api/v1/repos/me/app/releases"];
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            createRelease(forgeOn($b, $fk), "me/app", "1.2.0", "", "One two", "Notes", false),
            wantRelease($b, $fk.url));
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[len($seen) - 1], $sent);
    }
}

func testGitlabHasNoPrereleases() {
    def fk as Fake init fake([]);
    try {
        createRelease(forgeOn("gitlab", $fk), "me/app", "1.2.0-rc1", "main", "", "", true);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertContains($e.message, "pre-releases");
    }
    testing.assertEqual(len(finish($fk)), 0);
}

func testUploadAsset() {
    def data as bytes init convert.bytesFromString("utf-8", "tarball");
    for (def b in BACKENDS) {
        def asset as string init RELEASE_GH;
        $asset = '{"id":41,"name":"app.tar.gz","content_type":"application/gzip","size":10,' +
            '"download_count":2,"browser_download_url":"https://forge.test/dl/app.tar.gz",' +
            '"url":"BASE/api/v3/repos/me/app/releases/assets/41"}';
        def replies as list of Reply init [answer(201, $asset)];
        def want as list of string init [
            "POST /api/uploads/repos/me/app/releases/40/assets?name=app.tar.gz"
        ];
        if ($b == "gitlab") {
            $replies = [answer(201, '{"message":"201 Created"}'), answer(201, LINK_GL)];
            $want = [
                "PUT /api/v4/projects/me/app/packages/generic/app/1.2.0/app.tar.gz",
                "POST /api/v4/projects/me/app/releases/1.2.0/assets/links"
            ];
        } elseif ($b == "forgejo") {
            $replies = [
                answer(
                    201,
                    '{"id":41,"name":"app.tar.gz","size":10,"download_count":2,' +
                        '"browser_download_url":"BASE/attachments/a1"}')
            ];
            $want = ["POST /api/v1/repos/me/app/releases/40/assets?name=app.tar.gz"];
        }
        def fk as Fake init fake($replies);
        def f as Forge init forgeOn($b, $fk);
        testing.assertEqual(
            uploadAsset($f, "me/app", wantRelease($b, $fk.url), "app.tar.gz", $data),
            wantAsset($b, $fk.url));
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        if ($b == "gitlab") {
            testing.assertEqual($seen[0].body, "tarball");
            testing.assertContains($seen[1].body, '"link_type":"package"');
        } elseif ($b == "forgejo") {
            testing.assertContains($seen[0].contentType, "multipart/form-data");
        } else {
            testing.assertEqual($seen[0].body, "tarball");
        }
    }
}

func testDownloadAsset() {
    for (def b in BACKENDS) {
        def want as list of string init ["GET /api/v3/repos/me/app/releases/assets/41"];
        if ($b == "gitlab") {
            $want = ["GET /api/v4/projects/me/app/packages/generic/app/1.2.0/app.tar.gz"];
        } elseif ($b == "forgejo") {
            $want = ["GET /attachments/a1"];
        }
        def fk as Fake init fake([raw("application/octet-stream", "tarball")]);
        def got as bytes init downloadAsset(forgeOn($b, $fk), wantAsset($b, $fk.url), 0);
        testing.assertEqual(convert.stringFromBytes("utf-8", $got), "tarball");
        expect($b, finish($fk), $want);
    }
}

func testDownloadRefusesAnAssetElsewhere() {
    for (def b in BACKENDS) {
        def fk as Fake init fake([]);
        def a as Asset init wantAsset($b, "https://elsewhere.test");
        try {
            downloadAsset(forgeOn($b, $fk), $a, 0);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertEqual($e.backend, $b);
            testing.assertEqual($e.status, 0);
        }
        testing.assertEqual(len(finish($fk)), 0);
    }
}

# --- branches and tags ------------------------------------------------------

func testBranches() {
    for (def b in BACKENDS) {
        def body as string init '[{"name":"main","commit":{"sha":"c0ffee"},"protected":true}]';
        def want as list of string init ["GET /api/v3/repos/me/app/branches?per_page=100"];
        if ($b == "gitlab") {
            $body = '[{"name":"main","commit":{"id":"c0ffee"},"protected":true,"default":true}]';
            $want = ["GET /api/v4/projects/me/app/repository/branches?per_page=100"];
        } elseif ($b == "forgejo") {
            $body = '[{"name":"main","commit":{"id":"c0ffee"},"protected":true}]';
            $want = ["GET /api/v1/repos/me/app/branches?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(
            branches(forgeOn($b, $fk), "me/app"),
            [Branch{name: "main", sha: "c0ffee", isProtected: true}]);
        expect($b, finish($fk), $want);
    }
}

func testCreateBranchFromTheDefault() {
    for (def b in BACKENDS) {
        def replies as list of Reply init [
            ok(REPO_GH),
            ok('{"sha":"c0ffee"}'),
            answer(201, '{"ref":"refs/heads/topic","object":{"sha":"c0ffee"}}')
        ];
        def want as list of string init [
            "GET /api/v3/repos/me/app",
            "GET /api/v3/repos/me/app/commits/main",
            "POST /api/v3/repos/me/app/git/refs"
        ];
        def sent as string init '{"ref":"refs/heads/topic","sha":"c0ffee"}';
        if ($b == "gitlab") {
            $replies = [ok(REPO_GL), answer(201, '{"name":"topic","commit":{"id":"c0ffee"}}')];
            $want = [
                "GET /api/v4/projects/me/app",
                "POST /api/v4/projects/me/app/repository/branches"
            ];
            $sent = '{"branch":"topic","ref":"main"}';
        } elseif ($b == "forgejo") {
            $replies = [answer(201, '{"name":"topic","commit":{"id":"c0ffee"}}')];
            $want = ["POST /api/v1/repos/me/app/branches"];
            $sent = '{"new_branch_name":"topic"}';
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            createBranch(forgeOn($b, $fk), "me/app", "topic", ""),
            Branch{name: "topic", sha: "c0ffee", isProtected: false});
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[len($seen) - 1], $sent);
    }
}

func testDeleteBranch() {
    for (def b in BACKENDS) {
        def want as list of string init ["DELETE /api/v3/repos/me/app/git/refs/heads/topic"];
        if ($b == "gitlab") {
            $want = ["DELETE /api/v4/projects/me/app/repository/branches/topic"];
        } elseif ($b == "forgejo") {
            $want = ["DELETE /api/v1/repos/me/app/branches/topic"];
        }
        def fk as Fake init fake([answer(204, "")]);
        deleteBranch(forgeOn($b, $fk), "me/app", "topic");
        expect($b, finish($fk), $want);
    }
}

func testTags() {
    for (def b in BACKENDS) {
        def body as string init '[{"name":"1.2.0","commit":{"sha":"c0ffee"}}]';
        def want as list of string init ["GET /api/v3/repos/me/app/tags?per_page=100"];
        if ($b == "gitlab") {
            $body = '[{"name":"1.2.0","commit":{"id":"c0ffee"},"message":"","protected":false}]';
            $want = ["GET /api/v4/projects/me/app/repository/tags?per_page=100"];
        } elseif ($b == "forgejo") {
            $body = '[{"name":"1.2.0","commit":{"sha":"c0ffee"},"message":""}]';
            $want = ["GET /api/v1/repos/me/app/tags?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        testing.assertEqual(
            tags(forgeOn($b, $fk), "me/app"),
            [Tag{name: "1.2.0", sha: "c0ffee", message: ""}]);
        expect($b, finish($fk), $want);
    }
}

func testCreateTag() {
    for (def b in BACKENDS) {
        def replies as list of Reply init [
            ok('{"sha":"c0ffee"}'),
            answer(201, '{"sha":"7a9"}'),
            answer(201, '{"ref":"refs/tags/1.2.0","object":{"sha":"7a9"}}')
        ];
        def want as list of string init [
            "GET /api/v3/repos/me/app/commits/main",
            "POST /api/v3/repos/me/app/git/tags",
            "POST /api/v3/repos/me/app/git/refs"
        ];
        def made as string init '{"name":"1.2.0","commit":{"sha":"c0ffee","id":"c0ffee"},' +
            '"message":"Release 1.2.0"}';
        if ($b == "gitlab") {
            $replies = [answer(201, $made)];
            $want = ["POST /api/v4/projects/me/app/repository/tags"];
        } elseif ($b == "forgejo") {
            $replies = [answer(201, $made)];
            $want = ["POST /api/v1/repos/me/app/tags"];
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            createTag(forgeOn($b, $fk), "me/app", "1.2.0", "main", "Release 1.2.0"),
            Tag{name: "1.2.0", sha: "c0ffee", message: "Release 1.2.0"});
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        if ($b == "gitlab") {
            expectBody($seen[0], '{"tag_name":"1.2.0","ref":"main","message":"Release 1.2.0"}');
        }
    }
}

func testGitlabTagOnTheDefaultBranch() {
    def fk as Fake init fake([
        ok(REPO_GL),
        answer(201, '{"name":"1.2.0","commit":{"id":"c0ffee"},"message":""}')
    ]);
    createTag(forgeOn("gitlab", $fk), "me/app", "1.2.0", "", "");
    def seen as list of Seen init finish($fk);
    expectBody($seen[1], '{"tag_name":"1.2.0","ref":"main"}');
}

func testDeleteTag() {
    for (def b in BACKENDS) {
        def want as list of string init ["DELETE /api/v3/repos/me/app/git/refs/tags/1.2.0"];
        if ($b == "gitlab") {
            $want = ["DELETE /api/v4/projects/me/app/repository/tags/1.2.0"];
        } elseif ($b == "forgejo") {
            $want = ["DELETE /api/v1/repos/me/app/tags/1.2.0"];
        }
        def fk as Fake init fake([answer(204, "")]);
        deleteTag(forgeOn($b, $fk), "me/app", "1.2.0");
        expect($b, finish($fk), $want);
    }
}

# --- files ------------------------------------------------------------------

func testReadFile() {
    for (def b in BACKENDS) {
        def want as list of string init ["GET /api/v3/repos/me/app/contents/docs/a.md?ref=main"];
        def media as string init "application/vnd.github.raw+json";
        if ($b == "gitlab") {
            $want = [
                "GET /api/v4/projects/me/app/repository/files/docs/a.md/raw?lfs=true&ref=main"
            ];
            $media = "text/plain";
        } elseif ($b == "forgejo") {
            $want = ["GET /api/v1/repos/me/app/media/docs/a.md?ref=main"];
            $media = "text/plain";
        }
        def fk as Fake init fake([raw($media, "# Docs\n")]);
        def got as bytes init readFile(forgeOn($b, $fk), "me/app", "docs/a.md", "main");
        testing.assertEqual(convert.stringFromBytes("utf-8", $got), "# Docs\n");
        expect($b, finish($fk), $want);
    }
}

func testWriteFile() {
    def data as bytes init convert.bytesFromString("utf-8", "1.2.0\n");
    for (def b in BACKENDS) {
        def replies as list of Reply init [
            answer(404, '{"message":"Not Found"}'),
            answer(201, '{"commit":{"sha":"c1"}}')
        ];
        def want as list of string init [
            "GET /api/v3/repos/me/app/contents/data/v.txt?ref=dev",
            "PUT /api/v3/repos/me/app/contents/data/v.txt"
        ];
        def sent as string init '{"branch":"dev","content":"MS4yLjAK","message":"bump"}';
        if ($b == "gitlab") {
            $replies = [answer(404, ""), answer(201, '{"id":"c1"}')];
            $want = [
                "HEAD /api/v4/projects/me/app/repository/files/data/v.txt?ref=dev",
                "POST /api/v4/projects/me/app/repository/commits"
            ];
            $sent = '{"branch":"dev","commit_message":"bump","actions":[{"action":"create",' +
                '"file_path":"data/v.txt","content":"MS4yLjAK","encoding":"base64"}]}';
        } elseif ($b == "forgejo") {
            $replies = [
                answer(404, '{"message":"Not Found"}'),
                answer(201, '{"commit":{"sha":"c1"}}')
            ];
            $want = [
                "GET /api/v1/repos/me/app/contents/data/v.txt?ref=dev",
                "POST /api/v1/repos/me/app/contents/data/v.txt"
            ];
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            writeFile(forgeOn($b, $fk), "me/app", "data/v.txt", $data, "bump", "dev"),
            "c1");
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[1], $sent);
    }
}

func testDeleteFile() {
    for (def b in BACKENDS) {
        def replies as list of Reply init [ok('{"sha":"b1"}'), ok('{"commit":{"sha":"c2"}}')];
        def want as list of string init [
            "GET /api/v3/repos/me/app/contents/data/v.txt?ref=dev",
            "DELETE /api/v3/repos/me/app/contents/data/v.txt"
        ];
        def sent as string init '{"branch":"dev","message":"drop","sha":"b1"}';
        if ($b == "gitlab") {
            $replies = [answer(201, '{"id":"c2"}')];
            $want = ["POST /api/v4/projects/me/app/repository/commits"];
            $sent = '{"branch":"dev","commit_message":"drop","actions":[{"action":"delete",' +
                '"file_path":"data/v.txt"}]}';
        } elseif ($b == "forgejo") {
            $want = [
                "GET /api/v1/repos/me/app/contents/data/v.txt?ref=dev",
                "DELETE /api/v1/repos/me/app/contents/data/v.txt"
            ];
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            deleteFile(forgeOn($b, $fk), "me/app", "data/v.txt", "drop", "dev"),
            "c2");
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[len($seen) - 1], $sent);
    }
}

func testListDirectory() {
    for (def b in BACKENDS) {
        def body as string init '[{"name":"a.md","path":"docs/a.md","type":"file","size":5,' +
            '"sha":"b1"},{"name":"img","path":"docs/img","type":"dir","size":0,"sha":"t1"},' +
            '{"name":"up","path":"docs/up","type":"symlink","size":2,"sha":"l1"},' +
            '{"name":"lib","path":"docs/lib","type":"submodule","size":0,"sha":"s1"}]';
        def want as list of string init ["GET /api/v3/repos/me/app/contents/docs?ref=main"];
        def size as int init 5;
        def linkSize as int init 2;
        def linkType as string init "symlink";
        def moduleType as string init "submodule";
        def replies as list of Reply init [];
        if ($b == "github") {
            # GitHub's contents listing names a symlink and a submodule
            # `file` (seen live on git/git): the deck reads the directory's
            # git tree instead, found through the parent's listing
            $replies = [
                ok('[{"name":"docs","path":"docs","type":"dir","size":0,"sha":"' + TREE + '"}]'),
                ok('{"sha":"' + TREE + '","truncated":false,"tree":[' +
                    '{"path":"a.md","mode":"100644","type":"blob","sha":"b1","size":5},' +
                    '{"path":"img","mode":"040000","type":"tree","sha":"t1"},' +
                    '{"path":"up","mode":"120000","type":"blob","sha":"l1","size":2},' +
                    '{"path":"lib","mode":"160000","type":"commit","sha":"s1"}]}')
            ];
            $want = [
                "GET /api/v3/repos/me/app/contents?ref=main",
                "GET /api/v3/repos/me/app/git/trees/" + TREE
            ];
        } elseif ($b == "gitlab") {
            $body = '[{"name":"a.md","path":"docs/a.md","type":"blob","mode":"100644","id":"b1"},' +
                '{"name":"img","path":"docs/img","type":"tree","mode":"040000","id":"t1"},' +
                '{"name":"up","path":"docs/up","type":"blob","mode":"120000","id":"l1"},' +
                '{"name":"lib","path":"docs/lib","type":"commit","mode":"160000","id":"s1"}]';
            $want = [
                "GET /api/v4/projects/me/app/repository/tree?pagination=keyset&path=docs&ref=main&per_page=100"
            ];
            $size = 0;
            $linkSize = 0;
        } elseif ($b == "forgejo") {
            $want = ["GET /api/v1/repos/me/app/contents/docs?ref=main"];
        }
        if (len($replies) == 0) {
            $replies = [ok($body)];
        }
        def fk as Fake init fake($replies);
        testing.assertEqual(
            listDirectory(forgeOn($b, $fk), "me/app", "docs", "main"),
            [
                Entry{name: "a.md", path: "docs/a.md", type: "file", size: $size, sha: "b1"},
                Entry{name: "img", path: "docs/img", type: "dir", size: 0, sha: "t1"},
                Entry{name: "up", path: "docs/up", type: $linkType, size: $linkSize, sha: "l1"},
                Entry{name: "lib", path: "docs/lib", type: $moduleType, size: 0, sha: "s1"}
            ]);
        expect($b, finish($fk), $want);
    }
}

# The root has no parent listing: its tree is the newest commit's on the ref,
# the default branch for "".
func testGithubRootDirectory() {
    def commits as string init '[{"sha":"' + SHA + '","commit":{"tree":{"sha":"' + TREE + '"}}}]';
    def tree as string init '{"sha":"' + TREE + '","truncated":false,"tree":[' +
        '{"path":"README.md","mode":"100644","type":"blob","sha":"r1","size":9}]}';
    def fk as Fake init fake([ok($commits), ok($tree), ok($commits), ok($tree)]);
    def f as Forge init forgeOn("github", $fk);
    testing.assertEqual(
        listDirectory($f, "me/app", "", "feature/x"),
        [Entry{name: "README.md", path: "README.md", type: "file", size: 9, sha: "r1"}]);
    listDirectory($f, "me/app", "", "");
    expect(
        "github",
        finish($fk),
        [
            "GET /api/v3/repos/me/app/commits?per_page=1&sha=feature%2Fx",
            "GET /api/v3/repos/me/app/git/trees/" + TREE,
            "GET /api/v3/repos/me/app/commits?per_page=1",
            "GET /api/v3/repos/me/app/git/trees/" + TREE
        ]);
}

func testGithubDirectoryErrors() {
    def parent as string init '[{"name":"docs","path":"docs","type":"dir","sha":"' + TREE + '"},' +
        '{"name":"x.md","path":"x.md","type":"file","sha":"' + TREE + '"}]';
    def fk as Fake init fake([
        ok($parent),
        ok($parent),
        ok($parent),
        ok('{"sha":"' + TREE + '","truncated":true,"tree":[]}'),
        ok("[]")
    ]);
    def f as Forge init forgeOn("github", $fk);
    for (def c in [
        ["nope", "no directory \"nope\" in me/app"],
        ["x.md", "\"x.md\" is not a directory"],
        ["docs", "cut the listing of \"docs\" short"],
        ["", "no commit on"]
    ]) {
        try {
            listDirectory($f, "me/app", $c[0], "");
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, ERROR_KIND);
            testing.assertContains($e.message, $c[1]);
        }
    }
    finish($fk);
    for (def bad in ["docs//img", "docs/..", "/docs"]) {
        try {
            listDirectory($f, "me/app", $bad, "");
            missed();
        } catch (e) {
            testing.assertContains($e.message, "a directory is a path of names");
        }
    }
}

# --- commit statuses --------------------------------------------------------

func testSetCommitStatus() {
    for (def b in BACKENDS) {
        def body as string init '{"context":"ci/build","state":"failure","description":"broke",' +
            '"target_url":"https://ci.test/1","creator":{"login":"bot"},' +
            '"created_at":"2026-11-05T10:00:00Z"}';
        def want as list of string init ["POST /api/v3/repos/me/app/statuses/" + SHA];
        def sent as string init '{"state":"failure","context":"ci/build","description":"broke",' +
            '"target_url":"https://ci.test/1"}';
        def forgeState as string init "failure";
        if ($b == "gitlab") {
            $body = '{"id":1,"name":"ci/build","status":"failed","description":"broke",' +
                '"target_url":"https://ci.test/1","author":{"username":"bot"},"ref":"main",' +
                '"created_at":"2026-11-05T10:00:00Z"}';
            $want = ["POST /api/v4/projects/me/app/statuses/" + SHA];
            $sent = '{"state":"failed","name":"ci/build","description":"broke",' +
                '"target_url":"https://ci.test/1"}';
            $forgeState = "failed";
        } elseif ($b == "forgejo") {
            $body = strings.replace($body, '"state":', '"status":');
            $want = ["POST /api/v1/repos/me/app/statuses/" + SHA];
        }
        def fk as Fake init fake([answer(201, $body)]);
        testing.assertEqual(
            setCommitStatus(
                forgeOn($b, $fk),
                "me/app",
                SHA,
                "failure",
                "ci/build",
                "broke",
                "https://ci.test/1"),
            CommitStatus{
                context: "ci/build",
                state: "failure",
                forgeState: $forgeState,
                description: "broke",
                targetUrl: "https://ci.test/1",
                creator: "bot",
                created: "2026-11-05T10:00:00Z"
            });
        def seen as list of Seen init finish($fk);
        expect($b, $seen, $want);
        expectBody($seen[0], $sent);
    }
}

func testGitlabSetsErrorAsCanceled() {
    def fk as Fake init fake([answer(201, '{"name":"ci","status":"canceled"}')]);
    def s as CommitStatus init setCommitStatus(
        forgeOn("gitlab", $fk),
        "me/app",
        SHA,
        "error",
        "ci",
        "",
        "");
    testing.assertEqual($s.state, "error");
    testing.assertEqual($s.forgeState, "canceled");
    expectBody(finish($fk)[0], '{"state":"canceled","name":"ci"}');
}

func testCommitStatuses() {
    for (def b in BACKENDS) {
        def body as string init '[{"id":2,"context":"ci/build","state":"pending"},' +
            '{"id":1,"context":"ci/lint","state":"error"}]';
        def want as list of string init [
            "GET /api/v3/repos/me/app/commits/" + SHA + "/statuses?per_page=100"
        ];
        def raws as list of string init ["pending", "error"];
        if ($b == "gitlab") {
            # GitLab lists oldest first (seen live): the deck turns it round
            $body = '[{"id":1,"name":"ci/lint","status":"canceled"},' +
                '{"id":2,"name":"ci/build","status":"running"}]';
            $want = [
                "GET /api/v4/projects/me/app/repository/commits/" + SHA +
                    "/statuses?all=true&per_page=100"
            ];
            $raws = ["running", "canceled"];
        } elseif ($b == "forgejo") {
            $body = strings.replace($body, '"state":', '"status":');
            $want = ["GET /api/v1/repos/me/app/commits/" + SHA + "/statuses?limit=50&page=1"];
        }
        def fk as Fake init fake([ok($body)]);
        def got as list of CommitStatus init commitStatuses(forgeOn($b, $fk), "me/app", SHA);
        testing.assertEqual(len($got), 2);
        testing.assertEqual($got[0].context, "ci/build");
        testing.assertEqual($got[0].state, "pending");
        testing.assertEqual($got[0].forgeState, $raws[0]);
        testing.assertEqual($got[1].state, "error");
        testing.assertEqual($got[1].forgeState, $raws[1]);
        expect($b, finish($fk), $want);
    }
}

# @deckyard/gitlab after 0.1.0 returns newest first itself: the order is read
# from the ids, so a list that is already newest first stays as it is.
func testGitlabStatusesInEitherOrder() {
    for (def body in [
        '[{"id":7,"name":"old","status":"success"},{"id":9,"name":"new","status":"failed"}]',
        '[{"id":9,"name":"new","status":"failed"},{"id":7,"name":"old","status":"success"}]'
    ]) {
        def fk as Fake init fake([ok($body)]);
        def got as list of CommitStatus init commitStatuses(forgeOn("gitlab", $fk), "me/app", SHA);
        testing.assertEqual([$got[0].context, $got[1].context], ["new", "old"]);
        finish($fk);
    }
}

func testStatusStates() {
    testing.assertEqual(STATUS_STATES, ["pending", "success", "failure", "error"]);
    def pairs as map of string to string init {
        "pending": "pending",
        "running": "pending",
        "created": "pending",
        "manual": "pending",
        "waiting_for_resource": "pending",
        "success": "success",
        "skipped": "success",
        "failure": "failure",
        "failed": "failure",
        "warning": "success",
        "error": "error",
        "canceled": "error",
        "something-new": "pending"
    };
    for (def raw in maps.keys($pairs)) {
        testing.assertEqual([$raw, normalState($raw)], [$raw, $pairs[$raw]]);
    }
    testing.assertEqual(gitlabStatusState("pending"), "pending");
    testing.assertEqual(gitlabStatusState("success"), "success");
    testing.assertEqual(gitlabStatusState("failure"), "failed");
    testing.assertEqual(gitlabStatusState("error"), "canceled");
}

func testStatusStateIsChecked() {
    def fk as Fake init fake([]);
    try {
        setCommitStatus(forgeOn("gitlab", $fk), "me/app", SHA, "failed", "ci", "", "");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
    }
    testing.assertEqual(len(finish($fk)), 0);
}

# --- errors -----------------------------------------------------------------

func testRefusalsBecomeCodehostErrors() {
    for (def b in BACKENDS) {
        def fk as Fake init fake([answer(404, '{"message":"Not Found"}')]);
        try {
            issue(forgeOn($b, $fk), "me/app", 99);
            missed();
        } catch (e) {
            def err as CodehostError init $e;
            testing.assertEqual($err.kind, "codehost");
            testing.assertEqual($err.backend, $b);
            testing.assertTrue(strings.startsWith($err.message, $b + ": GET "));
            testing.assertContains($err.message, "HTTP 404");
            testing.assertEqual($err.status, 404);
        }
        finish($fk);
    }
}

func testAZeroForgeHasNoBackend() {
    def f as Forge;
    try {
        repository($f, "me/app");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.backend, "");
        testing.assertContains($e.message, "no backend");
    }
    try {
        changeRequests($f, "me/app", "open");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertContains($e.message, "no backend");
    }
}

func testLocalChecksOfABackend() {
    # the github deck's own check (no request) is a CodehostError too
    try {
        repository(fromGithub(github.client("github.com")), "not a repo");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.status, 0);
        testing.assertTrue(strings.startsWith($e.message, "github: "));
    }
    try {
        changeRequests(fromForgejo(forgejo.client("forge.test")), "me/app", "opened");
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertTrue(strings.startsWith($e.message, "codehost: "));
    }
}

func testOtherKindsAreRebuilt() {
    def f as Forge init fromForgejo(forgejo.client("forge.test"));
    try {
        failFrom($f, "runtime", "index out of range", 0);
        missed();
    } catch (e) {
        testing.assertEqual($e.kind, ERROR_KIND);
        testing.assertEqual($e.message, "forgejo: runtime: index out of range");
        testing.assertEqual($e.backend, "forgejo");
    }
    try {
        failFrom($f, "forgejo", "forgejo: GET /x: HTTP 500", 500);
        missed();
    } catch (e) {
        testing.assertEqual($e.message, "forgejo: GET /x: HTTP 500");
        testing.assertEqual($e.status, 500);
    }
    for (def kind in ["limit", "timeout", "closed", "cancelled", "codehost"]) {
        testing.assertTrue(passes($kind));
    }
    for (def kind in ["github", "gitlab", "forgejo", "runtime", "value"]) {
        testing.assertFalse(passes($kind));
    }
}

func testLimitPassesThrough() {
    for (def b in BACKENDS) {
        def fk as Fake init fake([raw("application/octet-stream", "far too long for the cap")]);
        try {
            downloadAsset(forgeOn($b, $fk), wantAsset($b, $fk.url), 4);
            missed();
        } catch (e) {
            testing.assertEqual($e.kind, "limit");
            testing.assertTrue(strings.startsWith($e.message, $b + ": "));
        }
        finish($fk);
    }
}

func testTimeoutPassesThrough() {
    for (def b in ["github", "gitlab"]) {
        def slow as Reply init ok(ISSUE_GH);
        $slow.delayMs = 600;
        def fk as Fake init fake([$slow]);
        def f as Forge init forgeOn($b, $fk);
        $f.github = github.withTimeout($f.github, 150);
        $f.gitlab = gitlab.withTimeout($f.gitlab, 150);
        try {
            issue($f, "me/app", 12);
            missed();
        } catch (e) {
            testing.assertEqual([$b, $e.kind], [$b, "timeout"]);
        }
        finish($fk);
    }
}

func testCancelledPassesThrough() {
    def slow as Reply init ok(ISSUE_GH);
    $slow.delayMs = 1500;
    def fk as Fake init fake([$slow]);
    def f as Forge init forgeOn("github", $fk);
    def t as task of string init spawn {
        try {
            issue($f, "me/app", 12);
        } catch (e) {
            return $e.kind;
        }
        return "none";
    };
    time.sleep(time.fromMilliseconds(200));
    task.cancel($t);
    testing.assertEqual(task.wait($t), "cancelled");
    finish($fk);
}
