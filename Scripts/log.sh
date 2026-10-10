#!/bin/zsh
# Streams the log of whichever Shotty runs: capture selection, frozen captures, text recognition, recordings, storage, launch and quit.
# Usage: Scripts/log.sh
# The full path matters in zsh, where plain `log` is a builtin.
exec /usr/bin/log stream --level debug --predicate 'subsystem == "local.markus.Shotty"'
