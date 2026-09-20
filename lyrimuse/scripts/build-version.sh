#!/bin/bash
set -euo pipefail
v="${1:-}"
v="${v#v}"
num='(0|[1-9][0-9]*)'
if [[ "$v" =~ ^$num\.$num\.$num$ ]]; then
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.1000"
elif [[ "$v" =~ ^$num\.$num\.$num-(alpha|beta|rc)\.([1-9][0-9]{0,2})$ ]]; then
  n="${BASH_REMATCH[5]}"
  case "${BASH_REMATCH[4]}" in
    alpha) (( n <= 99 )) || exit 1; b=$n ;;
    beta)  (( n <= 399 )) || exit 1; b=$((100 + n)) ;;
    rc)    (( n <= 499 )) || exit 1; b=$((500 + n)) ;;
  esac
  echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}.$b"
else
  exit 1
fi
