<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Contributing

Contributions should be focused, tested, and licensed for inclusion in this
repository. By submitting a contribution, you represent that you have the
right to submit it under the license that applies to the destination file. New
original code and configuration default to GPL-3.0-or-later; new original
documentation and artwork default to CC-BY-SA-4.0 unless an accepted change
states another compatible license.

Preserve upstream copyright, contributor, and license notices. Do not import
code, artwork, fonts, firmware, or data solely because it is publicly
accessible. Record the source URL, immutable revision, SHA-256 digest, and
license for each vendored input in `release/source-manifest.json`.

Git author information must identify the person who actually authored the
change. Committer information must identify the person who performed that Git
action. Do not add false co-author trailers or rewrite prior contributors as a
current maintainer. Tools and automated workflows must not add assistant,
generated-by, or bot attribution to a person's commit, and CI must not push
source commits.

Before proposing a change, run the relevant tests plus:

```sh
./scripts/validate.sh
./tests/test-release-metadata.sh
```

Never commit private keys, signing homes, repository credentials, tenant data,
generated packages, ISO output, or build logs. Security-sensitive findings
belong in a private security report as described in `SECURITY.md`.
