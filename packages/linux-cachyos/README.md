# CachyOS kernel packaging

Devario builds and signs `linux-cachyos` in its own repository. The live
and installed systems do not configure or trust a CachyOS binary repository.

The recipe and configuration are derived from CachyOS `linux-cachyos` at
commit `7071f528d7201df34d27000f6cdb2a6fbe344176`, currently packaging Linux
7.2.7. Devario deliberately changes the upstream processor selection to
`generic_v1`; leaving it empty enables `X86_NATIVE_CPU` and can produce an ISO
that only boots on the build machine's CPU class.

The release tarball and vendored configuration both have pinned BLAKE2
checksums in `PKGBUILD`. Before updating the package:

1. Review and verify the new upstream CachyOS tag, recipe, configuration,
   and release signature.
2. Update the pinned upstream commit comment, kernel version/tag, release
   tarball checksum, and the vendored `config` together.
3. Preserve `_processor_opt=generic_v1` and Devario's build-host identity.
4. Run `./scripts/validate.sh` and build the package in the baseline container:

   ```sh
   sudo ./scripts/build-packages-nspawn.sh linux-cachyos
   ```

5. Publish the kernel, headers, repository database, and corresponding source
   materials with Devario signatures, then test live and installed BIOS/UEFI
   boot plus a kernel upgrade.
