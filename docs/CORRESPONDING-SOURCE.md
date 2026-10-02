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

For the kernel, include the exact Seafoam Labs release source and signature, Devario configuration, package recipe, and all local
changes. For offline Zig caches, retain the cache itself, every embedded
license, and the immutable URL/revision recorded for every cached component.

Kernel and dracut recipes are maintained outside this OS repository. Their
external build must retain the same source and configuration evidence. Removing
their former paths from the OS source manifest does not remove their binaries
from the release source-index coverage requirement.

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

The canonical checked-in schema is `release/source-index.schema.json`. Each
entry repeats the exact installed package `name`, `version`, `architecture`,
and `packageBase`, binds the package archive inside the candidate artifact tree
by relative path, SHA-256, and size, and lists one or more immutable HTTPS
source locations with their revision and digest. For example:

```json
{
  "name": "devario-base",
  "version": "1-1",
  "architecture": "any",
  "packageBase": "devario-base",
  "binary": {
    "path": "core/devario-base-1-1-any.pkg.tar.zst",
    "sha256": "<64 lowercase hexadecimal characters>",
    "size": 1234
  },
  "sources": [{
    "uri": "https://example.invalid/immutable/source.tar.zst",
    "revision": "immutable revision",
    "sha256": "<64 lowercase hexadecimal characters>",
    "correspondingSource": true
  }]
}
```

Release metadata generation rejects an index unless it exactly covers the
package inventory extracted from the final ISO and every `binary` entry equals
an actual candidate artifact. Candidate validation repeats those checks and
verifies that the installed-package SPDX document carries the same binary and
source mapping.

Do not publish a binary while its corresponding-source entry is missing,
ambiguous, dependent on an unpinned network resource, or subject to unresolved
redistribution terms.

## Imported-source history

`release/source-manifest.json` distinguishes two immutable revisions. Its
`sourceRevision` is the initial commit that imported the source inventory into
`devario-os`; it is not a self-reference to a future release commit. Its
`importedFrom` object records the exact former monorepository URL and commit.
Release metadata separately records the current core commit. These fields must
not be rewritten to make an old source archive appear to have been imported
from a newer revision.

The checked-in manifest is validated against
`release/source-manifest.schema.json` and each recorded file is rehashed before
release metadata is produced. The immutable release source location retains
that manifest, the matching source files, source-package metadata, and signed
source checksums for as long as the binary is offered (or longer when its
license requires it).
