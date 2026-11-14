#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# SPDX-FileCopyrightText: Copyright (C) 2026 mplx <mplx@jennifer-lang.dev>
#
# How this deck's examples are checked. This file belongs to the deck, not to
# the shared CI layer: the workflows call it, and it is the place to say what
# the examples need.
#
# The examples talk to a live forge: triage.j reads github.com, gitlab.com or
# codeberg.org anonymously, release.j writes with a token. CI must not depend
# on a third-party service being up (nor spend its anonymous rate limit), so
# it parses them and does not run them.
#
# Usage: tools/check-examples.sh
set -euo pipefail
cd "$(dirname "$0")/.."
exec env EXAMPLES_SKIP_RUN=1 tools/check-examples-shared.sh "$@"
