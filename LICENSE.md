<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Licensing

This repository is an aggregate work. It does not replace the license notices
inside upstream projects, source archives, patches, packages, fonts, firmware,
artwork, or other third-party material.

Unless a file or directory says otherwise:

- original Devario code, build scripts, configuration, and patches are offered
  by their respective copyright holders under
  [GPL-3.0-or-later](https://spdx.org/licenses/GPL-3.0-or-later.html); and
- original Devario documentation and artwork are offered by their respective
  copyright holders under
  [CC-BY-SA-4.0](https://spdx.org/licenses/CC-BY-SA-4.0.html).

Those defaults apply only to rights a contributor is legally able to grant.
They do not assert that Seafoam Labs, Devario, or any one contributor owns work
created by someone else. A file-specific SPDX identifier, copyright notice,
license file, or upstream notice takes precedence over these defaults.

The `license` array in an Arch `PKGBUILD` describes the software produced by
that recipe. It is not, by itself, a blanket license for the recipe, patches,
vendored archives, or the repository as a whole.

Vendored source archives retain their upstream licenses and notices. Their
origin, digest, and declared license are recorded in
[`release/source-manifest.json`](release/source-manifest.json). Binary releases
must include the notices and corresponding source required by each applicable
license; see [`docs/RELEASE-POLICY.md`](docs/RELEASE-POLICY.md).

The Devario names and logos may also be protected by trademark law. Copyright
licenses do not grant trademark rights. See [`TRADEMARKS.md`](TRADEMARKS.md).

Before the first public release, the release owner must complete the licensing
gate in the release policy. In particular, confirm that every unmarked original
file was contributed under the applicable default and that each third-party
notice is preserved. When that cannot be established, remove the material or
obtain a documented license before distribution.
