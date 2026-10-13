# Devario's welcome display is only for interactive terminals.
status is-interactive; or return

# Remember the terminal, so an inherited marker cannot suppress a new window.
if isatty stdout; and set -q TERM; and test "$TERM" != dumb; and command -q fastfetch
    set -l devario_fastfetch_tty (tty <&1)
    if test "$DEVARIO_FASTFETCH_TTY" != "$devario_fastfetch_tty"
        if fastfetch
            set -gx DEVARIO_FASTFETCH_TTY "$devario_fastfetch_tty"
        end
    end
end
