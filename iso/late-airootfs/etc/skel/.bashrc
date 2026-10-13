#
# ~/.bashrc
#

# If not running interactively, don't do anything.
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Remember the terminal, so an inherited marker cannot suppress a new window.
if [[ -t 1 && ${TERM:-dumb} != dumb ]] \
  && command -v fastfetch >/dev/null 2>&1; then
  devario_fastfetch_tty=$(tty <&1)
  if [[ ${DEVARIO_FASTFETCH_TTY:-} != "$devario_fastfetch_tty" ]]; then
    if fastfetch; then
      export DEVARIO_FASTFETCH_TTY="$devario_fastfetch_tty"
    fi
  fi
  unset devario_fastfetch_tty
fi

PS1='[\u@\h \W]\$ '
