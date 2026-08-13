<!-- SPDX-FileCopyrightText: Copyright (c) respective contributors -->
<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->

# Security policy

## Reporting a vulnerability

Report security issues privately through the repository's GitHub Security
Advisory interface. Do not open a public issue for an unpatched vulnerability,
credential, signing-key exposure, or customer-specific managed configuration.

Include the affected revision or release, impact, reproduction details, and any
known workaround. Do not include real credentials, personal data, or private
keys. The project does not promise a response-time SLA until one is published,
but reports will be triaged according to severity and exploitability.

## Supported releases

Until an explicit lifecycle table is published, only the newest signed stable
release is supported. Development images and unsigned local repositories are
for testing and do not receive a security support commitment.

## Supply-chain incidents

Treat any of the following as a security incident:

- a private signing key or repository credential enters Git history;
- a production artifact is signed by the checked-in development key;
- an artifact digest differs between build, promotion, and publication;
- a Community image contains a managed key, managed repository URL, tenant
  identifier, enrollment secret, or proprietary payload; or
- required corresponding source, license notices, SBOM, or provenance is
  missing from a published release.

The checked-in key fingerprint
`E199A52D6C3B80057E08C7BB645354F2E56FEC5D` is development-only. Its private
material must never be committed, copied into an image, or used to sign a
production channel. If production trust is suspected to be compromised, stop
publication, preserve evidence, revoke the affected key through a still-trusted
path, and issue a documented recovery release.
