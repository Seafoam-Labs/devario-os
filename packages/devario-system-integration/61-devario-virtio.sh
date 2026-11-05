# Import the allocator choice into the whole UWSM session, including clients.
if /usr/lib/devario/graphics-session --detect-virtio; then
    export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-zink}"
    if [ "$MESA_LOADER_DRIVER_OVERRIDE" = zink ]; then
        export LIBGL_KOPPER_DRI2="${LIBGL_KOPPER_DRI2:-true}"
    fi
fi
