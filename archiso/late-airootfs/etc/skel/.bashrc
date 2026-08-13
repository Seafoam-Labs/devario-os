#
# ~/.bashrc
#

# If not running interactively, don't do anything.
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Show system information once per terminal, but not again in nested shells.
if [[ -t 1 && ${TERM:-dumb} != dumb \
  && -z ${DEVARIO_FASTFETCH_SHOWN:-} ]] \
  && command -v fastfetch >/dev/null 2>&1; then
  export DEVARIO_FASTFETCH_SHOWN=1
  fastfetch \
    -l /usr/share/devario/fastfetch/devario-fish.txt \
    --config /usr/share/devario/fastfetch/config.jsonc
fi

PS1='[\u@\h \W]\$ '
