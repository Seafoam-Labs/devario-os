# Import the allocator choice into the whole UWSM session, including clients.
if /usr/lib/devario/graphics-session --detect-virtio; then
    export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-zink}"
fi
