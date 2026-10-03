# Devario's welcome display is only for interactive terminals.
status is-interactive; or return

# Show system information once per terminal, including across nested shells.
if isatty stdout; and set -q TERM; and test "$TERM" != dumb; and test -z "$DEVARIO_FASTFETCH_SHOWN"; and command -q fastfetch
    set -gx DEVARIO_FASTFETCH_SHOWN 1
    fastfetch \
        -l /usr/share/devario/fastfetch/devario-fish.txt \
        --config /usr/share/devario/fastfetch/config.jsonc
end
