#!/usr/bin/env bash
# Creates an app user (or resets its password) by running
# `flask create-user` inside a running app pod. Safe to run again.
#
#   scripts/create-app-user.sh admin            # asks for the password
#   APP_USER_PASSWORD=... scripts/create-app-user.sh smoke   # for scripts/CI
#
# The password is sent on stdin, never as a command-line argument, so it
# does not show up in the process list or in `kubectl` logs.
set -euo pipefail

NAMESPACE=inventory
USERNAME=${1:?usage: $0 <username>}

if [[ -z ${APP_USER_PASSWORD:-} ]]; then
  read -rsp "Password for $USERNAME (min 12 characters): " APP_USER_PASSWORD; echo
  read -rsp "Repeat: " repeat; echo
  if [[ $APP_USER_PASSWORD != "$repeat" ]]; then
    echo "Passwords do not match" >&2
    exit 1
  fi
fi

# The command asks for the password twice (password + confirmation).
# Only its result line is shown ("User ... created" or "Error: ..."); the
# prompts and the app's startup log are dropped. If neither line appears,
# grep fails and so does this script.
printf '%s\n%s\n' "$APP_USER_PASSWORD" "$APP_USER_PASSWORD" |
  kubectl -n "$NAMESPACE" exec -i deploy/app -c app -- flask create-user "$USERNAME" 2>&1 |
  grep -oE "(User '|Error: ).*"
