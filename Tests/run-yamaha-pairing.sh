#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/telaerox-yamaha-checks.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -default-isolation MainActor -module-cache-path "$check_dir/modules" \
  TelAerox155/YConnectKit/Checksum.swift TelAerox155/YConnectKit/AuthFrame.swift \
  TelAerox155/PairingCredentials.swift TelAerox155/PairingConfirmation.swift \
  TelAerox155/YamahaPairingAPI.swift TelAerox155/GigyaJWTRequest.swift Tests/YamahaPairingRequestChecks.swift -o "$check_dir/checks"
"$check_dir/checks" "$@"
