#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.27.0
# pragma-jennifer-capability: net

/**
 * Summarize a repository on any forge: its latest release, its open change
 * requests and its open issues without a label. The same code runs on all
 * three backends.
 *
 *   jennifer run examples/triage.j github BurntSushi/ripgrep
 *   jennifer run examples/triage.j gitlab gitlab-org/cli
 *   jennifer run examples/triage.j forgejo forgejo/forgejo
 *
 * Reads public data anonymously from github.com, gitlab.com or codeberg.org;
 * set FORGE_URL and FORGE_TOKEN for another instance or a private
 * repository.
 */
use io;
use maps;
use os;

import "../src/codehost.j" as codehost;

if (len(os.ARGS) != 3) {
    throw Error{kind: "usage", message: "usage: triage.j github|gitlab|forgejo <owner/name>"};
}
def backend as string init os.ARGS[1];
def repo as string init os.ARGS[2];
def url as string init os.getEnv("FORGE_URL");
def token as string init os.getEnv("FORGE_TOKEN");

/**
 * The forge a backend name and the environment ask for.
 *
 * @param name {string} `github`, `gitlab` or `forgejo`
 * @return {codehost.Forge} the forge
 */
func forgeFor(name as string) {
    def hosts as map of string to string init {
        "github": "github.com",
        "gitlab": "gitlab.com",
        "forgejo": "codeberg.org"
    };
    if (not maps.has($hosts, $name)) {
        throw Error{kind: "usage", message: "a backend is github, gitlab or forgejo"};
    }
    return codehost.connect($name, orDefault($url, $hosts[$name]), $token);
}

/**
 * A value, or a fallback for "".
 *
 * @param value {string} the value
 * @param fallback {string} the fallback
 * @return {string} the value or the fallback
 */
func orDefault(value as string, fallback as string) {
    if ($value == "") {
        return $fallback;
    }
    return $value;
}

def f as codehost.Forge init forgeFor($backend);
def r as codehost.Repository init codehost.repository($f, $repo);
io.printf(
    "%s on %s: default branch %s, %d stars\n",
    $r.fullName,
    $f.backend,
    $r.defaultBranch,
    $r.stars);

# A repository without releases answers 404 here.
try {
    def rel as codehost.Release init codehost.latestRelease($f, $repo);
    io.printf("latest release %s, %d assets\n", $rel.tag, len($rel.assets));
} catch (e) {
    if ($e.kind != codehost.ERROR_KIND or $e.status != 404) {
        throw $e;
    }
    io.printf("no releases\n");
}

for (def c in codehost.changeRequests($f, $repo, "open")) {
    def draft as string init "";
    if ($c.isDraft) {
        $draft = " (draft)";
    }
    io.printf("  open !%d %s%s\n", $c.number, $c.title, $draft);
}
for (def i in codehost.issues($f, $repo, "open")) {
    if (len($i.labels) == 0) {
        io.printf("  unlabelled #%d %s\n", $i.number, $i.title);
    }
}
