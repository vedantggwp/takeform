#!/bin/bash

set -euo pipefail

target="${TAKEFORM_BROWSER_EXECUTABLE:-}"
if [[ -z "$target" || ! -x "$target" ]]; then
  printf '%s\n' 'BROWSER_WRAPPER_TARGET_UNAVAILABLE' >&2
  exit 64
fi

filtered=()
for argument in "$@"; do
  case "$argument" in
    --no-sandbox|--disable-setuid-sandbox)
      ;;
    --disable-web-security|--ignore-certificate-errors|--allow-running-insecure-content|--disable-site-isolation-trials)
      printf '%s\n' 'BROWSER_WRAPPER_REJECTED_SECURITY_ARGUMENT' >&2
      exit 64
      ;;
    --disable-features=*)
      features=",${argument#--disable-features=},"
      if [[ "$features" == *",IsolateOrigins,"* || "$features" == *",site-per-process,"* || "$features" == *",LocalNetworkAccessChecks,"* || "$features" == *",BlockInsecurePrivateNetworkRequests,"* || "$features" == *",PrivateNetworkAccessChecks,"* || "$features" == *",PrivateNetworkAccessPreflights,"* || "$features" == *",PrivateNetworkAccessSendPreflights,"* || "$features" == *",PrivateNetworkAccessRespectPreflightResults,"* ]]; then
        printf '%s\n' 'BROWSER_WRAPPER_REJECTED_SECURITY_ARGUMENT' >&2
        exit 64
      fi
      filtered+=("$argument")
      ;;
    *)
      filtered+=("$argument")
      ;;
  esac
done

if (( ${#filtered[@]} )); then
  exec "$target" "${filtered[@]}"
fi
exec "$target"
