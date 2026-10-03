# Calamares with Pearl appearance

Devario builds Calamares 3.4.2 with its Wayland runtime patch and a focused Qt
presentation patch. Installation jobs remain configured in
`iso/airootfs/etc/calamares/settings.conf`. The presentation patch adds the
application palette, native control style, page scrolling, a compact sidebar for narrow logical screens, layout spacing and
wrapped requirement messages; it does not change partition operations or the
installation sequence.

## Appearance source

`tools/calamares-theme/tokens.json` records the measured Pearl default colors,
font, spacing and motion, with the reference revision. The Qt style, QML and SVG
artwork are original Devario implementations; Pearl source and artwork are not
vendored. The reference is Pearl's opaque application/Settings surfaces. Window
shadows and outside window rounding remain compositor-owned. The installer does
not request shell-panel blur or depend on a GPU blur effect.

`tools/calamares-theme/` holds the editable QSS and QML templates.
`scripts/render-calamares-theme.py` generates the complete branding tree at
`iso/airootfs/usr/share/calamares/branding/devario`. There is deliberately no
`/etc/calamares/branding/devario` override: Calamares searches that location
before `/usr/share`, which previously let runtime styling differ from validation.

Run from the repository root:

```sh
python3 scripts/render-calamares-theme.py
python3 scripts/render-calamares-theme.py --check
```

The shipped default is dark, with Inter at 14 logical pixels and 150ms button
and sidebar transitions. Inter and Noto Sans are package dependencies; Noto Sans
also supplies fallback glyphs. Both palettes use semantic foreground/background
pairs, including distinct checked and partially checked indicators. Widgets keep
their native keyboard handling and accessibility interfaces. The sidebar displays
progress without allowing a click to bypass a page's validation. Navigation uses
the existing ViewManager button labels, visibility and enabled state.

Set `variant` to `light` or `reducedMotion` to `true` in `tokens.json`, then render,
to change the packaged default. For temporary previews without changing it:

```sh
python3 scripts/render-calamares-theme.py --variant light --output /tmp/devario-light
python3 scripts/render-calamares-theme.py --reduced-motion --output /tmp/devario-reduced
```

Reduced motion disables hover/sidebar transitions and automatic slideshow
rotation. Live wallpaper-derived colors and reading a user's personal settings
are outside this fixed-default installer theme.

## Elevated launch and maintenance

The package selects Qt's generic platform theme before QApplication starts, then
loads `theme.json` and the stylesheet from the resolved Devario branding directory.
This makes the installer independent of the caller's GTK/QtEngine plugin and root's
personal configuration. A malformed Devario theme stops startup with a diagnostic
instead of leaving partially styled destructive controls. The application palette
and stylesheet cover detached dialogs as well as the main window. Other branding
components retain their own stylesheet path.

QtEngine + Darkly was evaluated as the desktop application-theme mechanism. This
installer uses a Fusion-based proxy style to reproduce Pearl pill controls and
motion without adding Darkly/KDE runtime dependencies or crossing the user/root
configuration boundary. Its QML sidebar and slideshow use the same generated
palette and motion values as Qt Widgets.

When changing `PearlStyle.cpp`, `PearlStyle.h`, or either patch, update the
PKGBUILD checksums and package release. `makepkg --verifysource` and
`makepkg --nobuild --nodeps` verify the source inputs and clean patch application.
On a Calamares update, verify the branding lookup, ViewManager lifecycle and QML
APIs against the new source before refreshing patches. Re-render and compare both
palettes against the chosen Pearl release whenever the reference changes.

## Verification

Calamares targets x86-64-v3. The recipe replaces host compiler flags and checks
the toolchain's C runtime startup objects before compiling. Build in a Devario
root with v3-compatible dependencies; a CachyOS v4 host toolchain is rejected.
The package step and ISO preflight inspect every ELF payload for ISA notes above
v3, including module libraries. These notes are a regression check, not a full
instruction audit; the controlled compiler target remains necessary.

`tests/test-calamares-theme.sh` builds a standalone Qt test executable and a
test-only capture library. It needs CMake, Ninja, a C++17 compiler, Python/PyYAML,
Qt 6 Widgets/Test/QuickWidgets/QML/SVG, and the Qt Quick Controls/Layout runtime
modules. It checks both palettes at 100%, 125%, 150% and 200%, each with normal
and reduced motion. Checks cover native keyboard actions, disabled buttons,
accessible checked state, detached-dialog palettes, contrast, QML loading and
malformed-theme rejection. Captures and test results go to ignored
`out/calamares-theme/`. Its partition-controls fixture uses synthetic data and
is explicitly not a storage-backend test.

To capture the actual view modules from a compiled Calamares tree:

```sh
python3 scripts/preview-calamares-theme.py --build /path/to/calamares-build
```

The preview creates temporary view-only configurations with no execution jobs,
disables live timezone changes, disconnects the system bus and never clicks a
control. Each page loads in its own process. Installed dependencies must be
resolvable; for dependencies staged outside the host system, supply their library
and Qt plugin paths. The partition page therefore has no real disks, the users
page begins with validation errors, and the summary has no installation choices.
These captures verify module loading and rendering, not an end-to-end flow.

The GitHub appearance job runs the standalone matrix. Source validation rejects
stale generated assets and duplicate branding in the composed image. Repository
checks remain `scripts/validate.sh` and `tests/test-release-metadata.sh`.

## Live-image acceptance still required

Before release, use the same locked candidate throughout the existing
`docs/IMAGE-ACCEPTANCE-MATRIX.md` process. Verify launch through the desktop's
`pkexec` entry, every installer page and dialog, long translations, RTL text,
keyboard-only operation, screen-reader speech, and real monitor scaling.
Exercise disk selection, manual partition dialogs, encryption/passphrase errors,
partition summary and confirmation, installation progress/failure, and restart.
Capture only synthetic credentials.

Complete disposable BIOS and UEFI installations and boot their installed disks.
Check the offered filesystems and encrypted/plain layouts affected by UI changes.
Keep screenshots, package/ISO hashes, logs and the signed graphical review with
the exact candidate. Headless tests and source builds do not satisfy those gates
or establish pixel-for-pixel parity with Pearl on real hardware.
