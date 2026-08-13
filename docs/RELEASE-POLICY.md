<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Release policy

This policy separates Community/core trust from managed-product trust and
defines the minimum evidence required before an artifact is published.

## Trust roots and channels

The core OS owns one production package-signing trust root and the logical
repositories `devario-core-testing` and `devario-core-stable`. Community
installations trust only the core root. The private managed overlay owns a
different production root and the logical repositories `devario-managed-pilot`
and `devario-managed-stable`. Managed installations trust both roots because
they consume the unchanged core artifacts plus managed-only packages.

The names above are logical channel identities. A repository endpoint may use
an equivalent path or ALPM section name, but it must not collapse the core and
managed signing authority into one key.

The checked-in development key
`E199A52D6C3B80057E08C7BB645354F2E56FEC5D` is not a production trust root.
Its UID contains an `.invalid` address, it expires on 2027-08-03, and it is
intended only for local development images. Production private keys are
offline-controlled or held in an approved signing service, never stored in Git,
CI variables exposed to builds, an ISO, or a repository checkout.

Promotion copies already-built bytes. It never rebuilds a package under the
same version, never re-signs a core package as managed, and never changes an
artifact after its digest is admitted to a channel. A managed release locks the
core Git commit and the SHA-256 digest of every consumed core artifact.

## Required release record

Each release has an immutable record containing:

- product edition, semantic or date-based version, architecture, and channel;
- exact core commit and, when applicable, exact managed-overlay commit;
- package archives, repository databases, ISO images, source bundles, and
  their SHA-256 digests;
- detached package/database signatures and a signature over
  `METADATA.SHA256SUMS`;
- `.PKGINFO` and `.BUILDINFO` for every locally built package;
- the checked-in vendored-source manifest and its digest;
- a complete corresponding-source index;
- an SPDX 2.3 SBOM for release artifacts and the installed image package set;
- an in-toto Statement v1 provenance document using the SLSA provenance v1
  predicate; and
- build logs with secrets removed, test results, and the identity of the person
  approving publication.

`release/generate-release-metadata.sh` produces the deterministic checksum,
artifact SBOM, and unsigned provenance documents. It deliberately cannot sign.
The approver compares the subjects against the staged artifacts before signing
the metadata checksum file through the production trust process.

## Release gates

No public or customer release may be promoted unless all gates pass.

1. **Identity:** the source commits identify their real authors and committers.
   Migration commits are authored and committed by `ZoeyErinBauer` with an
   account-verified email and contain no false co-author or automation trailer.
2. **Clean source:** the release is built from committed source at an immutable
   revision. `git status --porcelain` is empty. Generated packages, build logs,
   credentials, signing homes, and raw image-generation work are absent.
3. **Licensing:** unmarked original material is confirmed under the defaults in
   `LICENSE.md`; third-party copyright/license notices are present; every
   binary has a corresponding-source mapping. Unresolved rights block release.
4. **Pinned inputs:** vendored inputs match `release/source-manifest.json`.
   Remote inputs use an immutable version or commit plus an accepted digest;
   `SKIP` checksums are forbidden for release inputs.
5. **Controlled build:** the build runs on the documented baseline environment
   with an explicit `SOURCE_DATE_EPOCH`. Compiler, linker, package-manager,
   Archiso, and keyring versions are captured.
6. **Boundary:** a Community image contains no managed package, managed public
   key, managed repository URL, tenant identifier, enrollment credential,
   business document, or managed policy default.
7. **Signatures:** every core package and repository database validates against
   the production core key. Managed packages and databases validate against the
   distinct managed key. The development key is rejected.
8. **Tests:** validation, unit tests, BIOS and UEFI boot, install, first boot,
   signed refresh/upgrade, package operations, key rotation, and applicable
   hardware tests pass on the exact candidate bytes.
9. **Evidence:** checksum files, SPDX SBOM, provenance, source index, package
   metadata, logs, and test results are complete and mutually consistent.
10. **Approval:** a named human release owner approves the digest set before
    signing and publication. Publishing automation does not commit source.

## Publication and promotion

Publish candidate bytes to a non-public staging location, generate and review
metadata, then sign the repository database and metadata checksum file. Upload
to a versioned immutable path before atomically updating the channel pointer.
Retain prior metadata so clients and responders can identify exactly what was
served.

Promote core artifacts from testing to stable by digest. A managed validation
record refers to those same core digests; it does not create a second core
patch stream. Pilot and stable managed channels may differ in managed-only
artifacts and rollout policy.

## Key rotation and revocation

Introduce a replacement public key in a keyring update signed by the currently
trusted key. Allow that trust update to reach supported installations before
signing repository content only with the replacement. During an intentional
overlap, document which keys are accepted and the exact end date.

For compromise, stop publication, preserve the affected digest set and logs,
remove the key from signing access, publish revocation through every remaining
trusted path, and issue a recovery keyring/repository release. Never silently
replace a key file at the same URL. Community and managed key incidents are
handled independently unless both roots are affected.

## Release retention

Retain signed release metadata, public keys, revocations, SBOMs, provenance,
and corresponding source for at least as long as the associated binaries are
offered and for any longer period required by an applicable license or written
offer. Customer entitlement may control access to proprietary managed
artifacts, but it must not prevent recipients from obtaining source they are
legally entitled to receive.
