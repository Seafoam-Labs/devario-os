# Sourced by UWSM before starting the compositor and importing the session
# environment. Avoid probing NVIDIA userspace drivers on non-NVIDIA machines:
# this can break the live Aqueous/Pearl session even when Mesa is available.
# --detect returns 1 only when PCI detection succeeded with no NVIDIA display
# controller; 2 means detection failed. Keep hybrid/NVIDIA systems unchanged.
if [ -x /usr/lib/devario/gpu-driver-setup ] &&
   [ -r /usr/share/glvnd/egl_vendor.d/50_mesa.json ]; then
    if /usr/lib/devario/gpu-driver-setup --detect >/dev/null 2>&1; then
        :
    else
        case $? in
            1)
                export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
                export VK_LOADER_DRIVERS_DISABLE="${VK_LOADER_DRIVERS_DISABLE:+${VK_LOADER_DRIVERS_DISABLE},}*nvidia*"
                ;;
        esac
    fi
fi
