# Calamares package

This package builds the unmodified upstream Calamares release from Codeberg. Devario-specific behavior lives in the Archiso filesystem overlay under `archiso/airootfs/etc/calamares` and `archiso/airootfs/usr/share/calamares/branding/devario`.

Keeping packaging separate from distribution configuration makes it possible to update Calamares without carrying another distribution's installer fork.

