# CachyOS LTS kernel packaging

Devario builds and signs `linux-cachyos-lts` in its own repository. The live
and installed systems do not configure or trust a CachyOS binary repository.

The recipe and configuration are derived from CachyOS `linux-cachyos-lts` at
commit `f6a87c3e8826aade3f62f15e968f9d6b99475909`, currently packaging Linux
6.18.42. Devario builds for the x86-64-v3 ISA level (`_processor_opt=generic_v3`),
so the kernel requires a CPU compatible with x86-64-v3 (roughly Intel Haswell
or AMD Zen and newer). `native` is never used for distributed packages, as it
produces a kernel that only boots on the build machine's CPU class.

The release tarball and vendored configuration both have pinned BLAKE2
checksums in `PKGBUILD`. Before updating the package:

1. Review and verify the new upstream CachyOS LTS tag, recipe, configuration,
   and release signature.
2. Update the pinned upstream commit comment, kernel version/tag, release
   tarball checksum, and the vendored `config` together.
3. Preserve `_processor_opt=generic_v3` and Devario's build-host identity.
4. Run `./scripts/validate.sh` and build the package in the baseline container:

   ```sh
   sudo ./scripts/build-packages-nspawn.sh linux-cachyos-lts
   ```

5. Publish the kernel, headers, repository database, and corresponding source
   materials with Devario signatures, then test live and installed BIOS/UEFI
   boot plus a kernel upgrade.
