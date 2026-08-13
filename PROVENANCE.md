<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Repository and release provenance

## Snapshot origin

The initial `devario-os` tree was selected from
`Seafoam-Labs/Devario@375faed39f9a37e348d5c4de089a4b0ef7e68ab9` as a clean
snapshot. The import commit must contain this source revision in its message.
It must not contain `Co-authored-by`, automation, assistant, or generated-by
trailers that did not exist in the source history.

The migration action is performed by the GitHub account `ZoeyErinBauer`.
Author and committer identity for each new migration commit must therefore be
configured explicitly as `ZoeyErinBauer` with an email verified for that
account. This records who performed the migration; it does not rewrite or
reassign earlier authorship. Prior contributors remain discoverable in the
original repository history and in retained notices.

Before pushing an import commit, verify it with:

```sh
git show --no-patch --format=fuller HEAD
git log --format='%H%n%an <%ae>%n%cn <%ce>%n%B%n---'
```

Do not use a mail map or history rewrite to make earlier contributors appear to
be `ZoeyErinBauer`. Automated workflows may validate or publish artifacts, but
they must not create source commits.

## Release provenance

Every published release records:

- the exact `devario-os` commit;
- the edition, version, architecture, and update channel;
- every input and output artifact SHA-256 digest;
- the checked-in vendored-source inventory digest;
- build start and finish times, builder identity, and invocation identifier;
- the complete package `.BUILDINFO` and `.PKGINFO` metadata;
- an SPDX release SBOM; and
- for a managed image, the exact managed-overlay commit and locked core digest.

`release/generate-release-metadata.sh` creates an unsigned checksum set, SPDX
artifact SBOM, and in-toto/SLSA-shaped provenance statement without reading a
private key. The release owner verifies those files and signs
`METADATA.SHA256SUMS` using the appropriate offline-controlled release key.
Generated provenance is evidence about declared inputs and outputs; a signature
and a controlled builder are required before it should be treated as an
attestation.
