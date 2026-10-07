#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/telaerox-sensor-checks.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -default-isolation MainActor -module-cache-path "$check_dir/modules" \
  TelAerox155/CSVCodec.swift TelAerox155/PhoneSensorSample.swift TelAerox155/HomeTelemetry.swift \
  TelAerox155/TripAnalysis.swift TelAerox155/TripPhoneAnalysis.swift \
  TelAerox155/SessionRecorder.swift TelAerox155/RecordingLibrary.swift \
  TelAerox155/YConnectKit/BinaryReader.swift TelAerox155/YConnectKit/Checksum.swift \
  TelAerox155/YConnectKit/Frame.swift TelAerox155/YConnectKit/Mapping.swift \
  TelAerox155/YConnectKit/TelemetryDecoder.swift TelAerox155/YConnectKit/BLELogFormat.swift \
  TelAerox155/YConnectKit/AuthFrame.swift TelAerox155/YConnectKit/PeriodicFrame.swift \
  TelAerox155/YConnectKit/YConnectClient.swift TelAerox155/YConnectKit/KeepAliveSchedule.swift \
  Tests/SensorRecordingChecks.swift -o "$check_dir/checks"
"$check_dir/checks"

xcrun swiftc -parse-as-library -default-isolation MainActor -module-cache-path "$check_dir/modules" \
  TelAerox155/YConnectKit/Checksum.swift TelAerox155/YConnectKit/AuthFrame.swift \
  TelAerox155/PairingCredentials.swift Tests/PairingChecks.swift -o "$check_dir/pairing-checks"
"$check_dir/pairing-checks"

bash Tests/run-yamaha-pairing.sh "$check_dir/yamaha-proof"
