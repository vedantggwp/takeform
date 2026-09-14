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
    --no-sandbox|--no-sandbox=*|--disable-setuid-sandbox|--disable-setuid-sandbox=*|--allow-running-insecure-content|--disable-site-isolation-trials)
      ;;
    --disable-web-security|--disable-web-security=*|--ignore-certificate-errors|--ignore-certificate-errors=*|--allow-insecure-localhost|--allow-insecure-localhost=*)
      printf '%s\n' 'BROWSER_WRAPPER_REJECTED_SECURITY_ARGUMENT' >&2
      exit 64
      ;;
    --disable-features=*)
      names="${argument#--disable-features=}"
      IFS=',' read -r -a requested <<< "$names"
      retained=()
      for name in "${requested[@]}"; do
        case "$name" in
          IsolateOrigins|site-per-process|LocalNetworkAccessChecks|BlockInsecurePrivateNetworkRequests|PrivateNetworkAccessChecks|PrivateNetworkAccessPreflights|PrivateNetworkAccessSendPreflights|PrivateNetworkAccessRespectPreflightResults)
            ;;
          *)
            [[ -n "$name" ]] && retained+=("$name")
            ;;
        esac
      done
      if (( ${#retained[@]} )); then
        joined="$(IFS=','; printf '%s' "${retained[*]}")"
        filtered+=("--disable-features=$joined")
      fi
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
