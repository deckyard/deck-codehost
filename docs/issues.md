<!-- SPDX-License-Identifier: LGPL-3.0-only -->
<!-- SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev> -->

# Issues and change requests

Snippets assume a forge `$f` built as in [the introduction](index.md) and
the import `import "@deckyard/codehost/" as codehost;`.

## Issues

```jennifer
for (def i in codehost.issues($f, "me/app", "open")) {
    io.printf("#%d %s [%s]\n", $i.number, $i.title, strings.join($i.labels, ", "));
}

def bug as codehost.Issue init codehost.createIssue($f, "me/app", "Crash on start", "Steps: ...");
codehost.comment($f, "me/app", $bug.number, "Reproduced on 1.2.0.");
codehost.closeIssue($f, "me/app", $bug.number);
codehost.reopenIssue($f, "me/app", $bug.number);
```

`issues` takes `open`, `closed` or `all` and lists issues only: GitHub™'s
listing mixes pull requests in, and the github deck drops them. `issue` of
a number that is a pull request's (GitHub and Forgejo™ share the numbering)
answers with `isChangeRequest` set.

`comments` lists an issue's comments oldest first. GitLab™ writes system
notes for events (a label change, a push); they are left out, as GitHub and
Forgejo do not list events as comments. `Issue.comments` counts the same.

## Labels

```jennifer
def names as list of string init codehost.addIssueLabels($f, "me/app", 12, ["needs-triage"]);
$names = codehost.setIssueLabels($f, "me/app", 12, ["bug", "p1"]);
codehost.removeIssueLabel($f, "me/app", 12, "p1");
```

Labels are names everywhere. A name that is no label of the repository
yet is created, on every forge: GitHub and GitLab do that themselves;
Forgejo drops a name it has no repository or organization label for, and
the deck creates those (colour `LABEL_COLOR`) and adds them. Both verbs answer
with the issue's label names afterwards. `createLabel` makes one with a
colour and description of your choice; `labels` lists them.

GitLab refuses a label name with a comma (it sends labels as one
comma-separated parameter). On GitHub, taking off a label the issue does not
have is a 404; GitLab and Forgejo do not mind.

## Change requests

A `ChangeRequest` is a GitHub or Forgejo pull request or a GitLab merge
request. Its `state` is `open`, `closed` (closed without merging) or
`merged`; `changeRequests` filters on those or `all`:

```jennifer
for (def c in codehost.changeRequests($f, "me/app", "open")) {
    def mark as string init "";
    if ($c.isDraft) {
        $mark = " (draft)";
    }
    io.printf("!%d %s -> %s: %s%s\n", $c.number, $c.head, $c.base, $c.title, $mark);
}
```

GitHub and Forgejo list merged pull requests as closed: `merged` and
`closed` ask for the closed ones and keep those of the state asked for.

```jennifer
def c as codehost.ChangeRequest init codehost.createChangeRequest(
    $f, "me/app", "fix-crash", "main", "Fix the crash on start", "Fixes #12.", true);
codehost.commentChangeRequest($f, "me/app", $c.number, "Ready for review.");
```

The last argument opens it as a draft. GitHub has a draft flag; GitLab and
Forgejo read a title prefix, so the deck sends `Draft: ` (GitLab) or `WIP: `
(Forgejo) in front of the title, unless it starts with a prefix that forge
reads already. Read back, `title` comes without the prefix and `isDraft` is
set. `mergeable` is false for a draft and for one that is not open, on
every forge (GitHub reports both as mergeable). On GitHub and Forgejo a `head` of
`user:branch` names a fork's branch.

## Merging

```jennifer
codehost.mergeChangeRequest($f, "me/app", $c.number, "squash", true);
def done as codehost.ChangeRequest init codehost.changeRequest($f, "me/app", $c.number);
io.printf("%s at %s\n", $done.state, $done.mergeSha);
```

| Style | GitHub | GitLab | Forgejo |
|---|---|---|---|
| `merge` | a merge commit | the project's merge method (a merge commit or a fast-forward) | a merge commit |
| `squash` | one squashed commit | squashed, then the project's merge method | one squashed commit |
| `rebase` | the commits rebased onto the base | refused | the commits rebased onto the base |

With `deleteBranch` the head branch is deleted afterwards, but only when it
lives in the same repository: a fork's branch is never touched. GitHub's
deck deletes it itself after the merge; GitLab and Forgejo delete it as
part of the merge (GitLab in the background, a moment after the merge
returns). A branch the forge deletes on its own by a setting goes either
way.

A change request that cannot be merged (a draft, conflicts, missing
approvals, failed checks) is a `CodehostError` with status 405; a head that
moved while you looked is 409. `mergeSha` is the commit the merge left on
the base branch: the merge commit, the squashed commit, or for a GitLab
fast-forward the head commit itself.

`closeChangeRequest` and `reopenChangeRequest` close one without merging
and open it again.
