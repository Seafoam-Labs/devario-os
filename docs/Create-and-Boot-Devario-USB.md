<p align="center"><img src="assets/devario-logo-transparent.png" alt="Devario" width="520"></p>

# Create and Boot a Devario USB Drive

Use these steps to create a bootable Devario USB drive from Windows, macOS, or
Linux.

## What You Need

- A USB drive with at least 8 GB of space
- A Devario `.iso` file
- A Windows, macOS, or Linux computer
- [balenaEtcher](https://etcher.balena.io/)

> **Warning:** Flashing the ISO erases everything on the selected USB drive.
> Check the drive's name and size carefully before continuing.

## Create the USB Drive

1. Download and install balenaEtcher from
   [etcher.balena.io](https://etcher.balena.io/).
2. Insert the USB drive into the computer.
3. Open balenaEtcher.
4. Select **Flash from file** and choose the Devario `.iso` file.
5. Select **Select target** and choose the USB drive.
6. Confirm that the selected drive's name and size match the USB drive. Do not
   select the computer's internal drive.
7. Select **Flash** and approve the administrator prompt if one appears.
8. Wait for flashing and validation to finish.
9. Safely eject the USB drive.

The USB drive is now ready to boot Devario.

## Boot Devario from the USB Drive

1. Shut down the computer on which you want to run Devario.
2. Insert the Devario USB drive.
3. Turn on the computer and immediately press its boot-menu key repeatedly.
   Common keys are **F12**, **F11**, **F9**, **Esc**, or **Delete**. The correct
   key depends on the computer manufacturer.
4. Select the USB drive from the boot menu. Choose its **UEFI** entry when both
   UEFI and legacy entries are available.
5. Select the Devario live-environment entry if a boot menu appears.
6. Wait for the Aqueous desktop to start.

Devario is now running from the USB drive. You can explore the live environment
without installing it. Changes made in the live environment are normally lost
after shutdown.

To start the installer, open **Calamares** from the application launcher or
press **Super+I**. Installing Devario changes the selected internal disk, so
review the installer's disk choice carefully before confirming installation.

## If the USB Does Not Boot

- Return to the firmware boot menu and confirm that the USB drive was selected.
- Try another USB port, preferably a port directly on the computer.
- Recreate the USB and allow balenaEtcher's validation step to finish.
- Disable **Secure Boot** in the computer's UEFI settings. Devario does not
  currently configure Secure Boot support.
- Try the legacy or BIOS USB entry when the computer does not boot the UEFI
  entry for live use. Installation requires the 64-bit UEFI entry.
