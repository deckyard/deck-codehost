#!/usr/bin/env -S jennifer run
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
# pragma-jennifer-version: >=0.26.0
# pragma-jennifer-capability: net

/**
 * Publish a release with a file attached, on whichever forge FORGE names,
 * and mark the tagged commit green.
 *
 *   FORGE=gitlab FORGE_URL=gitlab.example.com FORGE_TOKEN=... \
 *       jennifer run examples/release.j me/app 1.3.0 dist/app-1.3.0.tar.gz
 *
 * It writes to the repository: run it against one of your own.
 */
use fs;
use io;
use os;
use path;

import "../src/codehost.j" as codehost;

if (len(os.ARGS) != 4) {
    throw Error{kind: "usage", message: "usage: release.j <owner/name> <tag> <file>"};
}
def repo as string init os.ARGS[1];
def tag as string init os.ARGS[2];
def file as string init os.ARGS[3];
def url as string init os.getEnv("FORGE_URL");
def token as string init os.getEnv("FORGE_TOKEN");

# FORGE names the backend: github, gitlab or forgejo
def f as codehost.Forge init codehost.connect(os.getEnv("FORGE"), $url, $token);

def r as codehost.Release init codehost.createRelease(
    $f,
    $repo,
    $tag,
    "",
    $tag,
    "Release " + $tag,
    false);
def a as codehost.Asset init codehost.uploadAsset(
    $f,
    $repo,
    $r,
    path.base($file),
    fs.readBytes($file));
io.printf("released %s with %s\n", $r.tag, $a.name);

def sha as string init "";
for (def t in codehost.tags($f, $repo)) {
    if ($t.name == $tag) {
        $sha = $t.sha;
    }
}
codehost.setCommitStatus($f, $repo, $sha, "success", "release", "published " + $tag, $r.htmlUrl);
