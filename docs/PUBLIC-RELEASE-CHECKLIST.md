<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Public release checklist

This checklist is a release-owner handoff. A checked source tree is not itself
evidence that a public release passed runtime, installation, or hardware tests.

- [ ] Core and (when applicable) overlay Git HEADs equal the candidate commits;
      worktrees, indexes, file modes, ignore sets, and index flags are clean.
- [ ] Controlled input locks and signed builder attestation validate
      semantically; `SOURCE_DATE_EPOCH`, snapshot databases, dependency closure,
      builder image, and exact source archives are pinned.
- [ ] Production core and Managed public bundles contain only classified public
      keys; the active signer is trusted, non-revoked, and not a development key.
- [ ] Every package, source package, and repository database verifies under its
      own edition's active signer. The packaged keyring bytes equal the checked
      release bundle.
- [ ] Release JSON, SPDX SBOM, in-toto/SLSA provenance, source manifest,
      final-image `IMAGE-PACKAGE-INVENTORY.json`, corresponding-source index,
      `.PKGINFO`, `.BUILDINFO`, and checksum manifests are complete. Every
      source-index binary digest is an exact candidate package artifact.
- [ ] Two distinct controlled invocations reproduce every deterministic subject.
      Differences are investigated and fixed; they are not waived.
- [ ] Community image-boundary scanning finds no Managed package, URL, public
      key, tenant/enrollment material, credential, secret packet, or business
      document anywhere in the image root.
- [ ] Exact live ISO passes BIOS and UEFI boots.
- [ ] Calamares graphical flow is manually reviewed and the review is signed by
      Zoey's active fixed approval key, with `reviewerFingerprint` recorded.
- [ ] Exact locked installed disk passes UEFI systemd-boot checks; qcow2 evidence has
      no backing or external data file.
- [ ] Required physical hardware, refresh/upgrade, rotation, recovery, and
      rollback tests have genuine retained evidence.
- [ ] Closed `promotion-acceptance.json` and canonical
      `ACCEPTANCE.SHA256SUMS` validate with no extra or writable files.
- [ ] Final approval binds the candidate, both evidence manifests,
      reproducibility, source/target channels, commits, and artifact set and is
      signed by Zoey's current fixed approval key. Managed approval also binds
      the exact semantically validated `managed-lock.json`; Community approval
      has no edition-specific evidence.
- [ ] Promotion creates a new immutable path by digest; it neither rebuilds,
      re-signs, nor overwrites candidate bytes. `promotion-record.json` and
      `PROMOTION.SHA256SUMS` validate after upload when supplied the original
      signed candidate, approval, reproducibility, acceptance closure, and
      exact Managed edition evidence when applicable.

Production private keys, the approval private key, customer secrets, and real
tenant enrollment credentials are supplied outside Git and outside the build
tree. Until the public keys and genuine evidence are provisioned, promotion is
expected to fail closed.
