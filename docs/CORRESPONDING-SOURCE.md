<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Corresponding-source procedure

This procedure is an engineering control, not a conclusion about any specific
legal obligation. The release owner must review the licenses actually present
in each candidate.

For every distributed binary package and ISO, create a source index mapping the
binary SHA-256 digest to the exact source, configuration, patches, and build
instructions used to produce it. The index covers locally built Devario
packages and third-party binary packages included from upstream repositories.

For locally built Arch packages, retain:

- the exact `PKGBUILD`, install files, patches, local sources, and vendored
  dependency caches;
- all remote sources fetched by `makepkg --allsource`, after
  `makepkg --verifysource` succeeds;
- `.SRCINFO`, `.PKGINFO`, and `.BUILDINFO`;
- generated files or scripts required to recreate the binary;
- compiler and build-tool versions, the baseline package inventory, and
  `SOURCE_DATE_EPOCH`; and
- applicable license and copyright notices.

For the kernel, include the exact upstream source, CachyOS patch set embodied
by the pinned release, Devario configuration, package recipe, and all local
changes. For offline Zig caches, retain the cache itself, every embedded
license, and the immutable URL/revision recorded for every cached component.

For third-party binary packages copied from Arch or another repository, record
the package digest and version and retain or mirror the exact corresponding
source package when the applicable license requires distribution of source.
A link to a mutable upstream page is not a reliable substitute for preserving
the source that matches the shipped binary.

Place release source material under a versioned immutable location alongside:

```text
source-index.json
SOURCE-SHA256SUMS
SOURCE-SHA256SUMS.sig
```

The index records binary-to-source relationships and license expressions. Sign
the source checksum file with the appropriate release metadata key. Verify the
download as an unauthenticated user before publication, and include a stable
source location in the release notes and package repository metadata.

Do not publish a binary while its corresponding-source entry is missing,
ambiguous, dependent on an unpinned network resource, or subject to unresolved
redistribution terms.
