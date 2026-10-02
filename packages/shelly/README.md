# Shelly for Devario

Install `shelly` from `devario-core`. The OS build no longer builds its own
Shelly recipe or the separate `devario-alpm-runtime` package.

The published Shelly **3.1.6-2** package uses its native **RLPM** backend and
has no dependency on `libalpm` or `devario-alpm-runtime`. Its package metadata
and archive were inspected on 2026-10-02 using the
[devario-core package index](https://repo.seafoam-labs.org/api/v1/packages?repository=devario-core).

Shelly ships the CLI, GTK UI, native keyring helper, notifications, completions,
manual page, translations, desktop entries, Polkit policy, and
`/etc/shellybuild.conf`. `devario-base` requires this release or newer and owns
`/etc/shelly.conf`, runtime directories, the download account, GnuPG socket
activation, and `shelly-storage-migrate.service`. It replaces the retired
runtime package so existing installations retain those Devario policies.

Supply Shelly and its dependency closure in the signed `devario-core`
repository snapshot used for ISO construction. The OS validator checks the
published artifact when present, including the native keyring helper and the
absence of an external ALPM dependency. Repository signatures, package
inventory, and installed-system acceptance checks still apply.
