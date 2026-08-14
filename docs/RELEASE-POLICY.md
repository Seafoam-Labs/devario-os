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
The Managed development signer
`580E40BB6D6E8745D69D89CC6E6C90512593874C` is equally forbidden for human
approval. Both development fingerprints are permanently listed in the fixed
approval policy and cannot be promoted into its approved set.

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

Every controlled build sets an explicit `SOURCE_DATE_EPOCH`, an HTTPS
`DEVARIO_BUILDER_ID`, and a unique `DEVARIO_INVOCATION_ID`. Metadata creation
is fixed to `Person: ZoeyErinBauer`; an environment variable cannot change that
identity. JSON release documents are validated with their checked-in Draft
2020-12 schemas, including duplicate-key rejection.

Every ISO build also receives its release version before construction. The
canonical value matches `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` and is identical
in the immutable core input lock, signed builder attestation, embedded
build-source record, final `/etc/os-release`, release metadata, and candidate
lock. A caller cannot name already-built bytes with a different version.

## Candidate and reproducibility contracts

`release/generate-candidate-lock.sh` creates candidate-lock version 2. It
locks every regular file, size, mode, and SHA-256 digest in the closed artifact
and metadata trees. It also binds the controlled core input lock, builder
manifest and detached signature, builder attestation and detached signature,
and, for Managed, the overlay input lock. The signed attestation covers the
exact builder output tree; a Managed attestation and core input lock both bind
the canonical `MANAGED-INPUT-LOCK.json`. Symlinks, special files, empty
directories, untracked build inputs, and placeholder evidence are not release
inputs. The publishable candidate artifact tree must be an exact path, digest,
and size subset of the attested builder outputs; per-run attestations and their
signatures remain evidence rather than reproducible release subjects.

For a production candidate, validation regenerates the core input lock from
the exact bootstrap archive/signature, immutable Arch snapshot databases,
Arch keyring, Shelly bootstrap/signature, controlled-builder manifest,
dependency closure, repository closures, and `SOURCE_DATE_EPOCH`. Managed
validation independently regenerates its input lock with the overlay-owned
validator and distinct keyring. Merely supplying JSON with matching digests is
not sufficient.

Two independent controlled invocations must produce the same deterministic
subjects. `scripts/compare-release-artifacts.sh` requires distinct invocation
IDs and distinct candidate-lock digests while requiring the same commits,
input-lock digests, `SOURCE_DATE_EPOCH`, and exact artifact bytes. Per-run SLSA
`runDetails` are retained but are deliberately not treated as reproducible
subjects. A difference cannot be waived in a final approval.

## Runtime acceptance and installation review

The exact candidate ISO boots under both BIOS and UEFI. The exact disk created
by Calamares then boots under both BIOS and UEFI. The four machine-readable
results and console logs use a single exact marker and are bound to the
candidate, ISO, installed-disk lock, and edition. An unrelated ISO, a qcow2
backing/data file, a second or suffixed marker, or a writable/extra evidence
file invalidates the evidence set.

The QEMU checks do not pretend to automate a graphical Calamares installation.
`installation-review.json` records the manual graphical review and is signed
by the fixed approval trust root. It names `ZoeyErinBauer` and includes the
current `reviewerFingerprint`; accepting a signer-selected public key is
forbidden. See [IMAGE-ACCEPTANCE-MATRIX.md](IMAGE-ACCEPTANCE-MATRIX.md).

`release/generate-promotion-acceptance.sh` finalizes the closed evidence tree
and canonical `ACCEPTANCE.SHA256SUMS`. `release/validate-promotion-acceptance.sh`
revalidates every nested schema, digest, result/log pair, disk, installation
lock, and review signature.

## Final approval and digest promotion

`release/generate-final-approval.sh` creates an unsigned approval template
binding the candidate, reproducibility report, acceptance manifest, evidence
checksum manifest, source commits, artifact set, source channel, and target
channel. A Managed approval additionally requires `--edition-evidence` and
binds the exact basename and SHA-256 digest of the overlay's semantically
validated `managed-lock.json`; Community approvals require this binding to be
null and reject the argument. `ZoeyErinBauer` signs those exact bytes with the
separately controlled active approval key. The generator cannot sign and
publishing automation cannot choose a replacement trust root.

`release/promote-candidate.sh` performs the final checks against clean Git
HEADs and the exact core/Managed production keyring bundles, revalidates every
package/database/source signature, then copies the already-approved bytes to a
new immutable destination. It does not rebuild or overwrite. The resulting
`promotion-record.json` and canonical `PROMOTION.SHA256SUMS` are checked by
`release/validate-promotion.sh`. Managed promotion retains the exact approved
`managed-lock.json` under the immutable `edition-evidence/` closure and
revalidates its name, digest, bytes, and read-only state. Community promotion
rejects that directory and binding.

Promotion validation is never based on the destination record alone. It must
also receive the exact candidate lock, signed approval and signature,
reproducibility report, acceptance manifest and checksum closure, source ISO,
expected target channel, and the exact Managed edition evidence when
applicable. Their digests are bound in the promotion record; fixed trust and
every nested acceptance binding are revalidated. A forged record plus newly
generated checksums therefore cannot authenticate a destination.

The only allowed transitions are `devario-core-testing` to
`devario-core-stable` for Community and `devario-managed-pilot` to
`devario-managed-stable` for Managed. Cross-edition and arbitrary channel
transitions fail before promotion.

The checked-in approval policy intentionally has no active key. A production
release remains fail-closed until Zoey provisions the real approval public key
and updates the fixed policy through an ordinary reviewed source commit. No
private key, customer credential, or synthetic acceptance result belongs in
this repository.

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
