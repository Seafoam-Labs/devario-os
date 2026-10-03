<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Image acceptance matrix

Every release candidate supplies all three automated boot results below. Each
result is produced by `scripts/test-image-boot.sh` from the exact locked bytes.
Every result, installation lock, signed review, and promotion-acceptance
manifest carries the exact candidate version as well as its lock digest.

| System under test | BIOS | UEFI | Required binding |
| --- | --- | --- | --- |
| Candidate live ISO | pass | pass | candidate-lock SHA-256 and exact ISO subject |
| Calamares-installed disk | unsupported | pass | candidate, source ISO, installation lock, exact disk |

The guest self-check requires the requested edition, firmware environment,
installed/live state, and exact section-scoped `SigLevel = Required` for
`[devario-core]` (and `[devario-managed]` for Managed). Each section must have
exactly one credential-free HTTPS `Server`. A global setting does not satisfy
the check. The self-check runs only after `shelly-keyring-init.service` succeeds
and requires its `/var/lib/devario/shelly-keyring.ready` marker. Community
rejects managed repository material. Installed checks also require the systemd-boot
marker, normal/fallback entries, and deployed EFI binaries. Promotion evidence
uses schema version 2; version 1 represented the previous four-case matrix.

The log must contain exactly one complete line in this form:

```text
DEVARIO_ACCEPTANCE:PASS mode=live firmware=bios edition=community
```

The values vary for the matrix cell. Extra text, a second PASS, any FAIL, or a
marker for a different edition/mode/firmware fails the run.

After the automated matrix, Zoey performs the graphical Calamares review on
the same candidate and installed-disk lock. The signed review confirms launch,
target selection, partition summary, bootloader choice, completion, and that no
credentials were captured. The review records the active approver fingerprint.
Real hardware checks required for a particular release are retained alongside
the release record; source validation never fabricates them.

For the dracut migration, additionally verify normal/fallback installed boot,
encrypted and plain root, the offered filesystem and swap/resume layouts,
copy-to-RAM installation after media removal, and kernel/dracut/DKMS/microcode
updates followed by reboot. Exercise generation failure and recovery, and
retained HTTP/NFS/NBD and loopback modes. The isolated
`tests/test-dracut-live-qemu.sh` probe covers the live-root mount contract only;
it does not satisfy any cell of the exact-candidate matrix above.
