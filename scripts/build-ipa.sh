#!/bin/bash
# Build TelAerox155 untuk iPhone lalu kemas menjadi file IPA.
#
# Script ini memakai CODE_SIGNING_ALLOWED=NO, jadi hasilnya adalah IPA tanpa
# tanda tangan (unsigned). Cocok untuk arsip/CI, bukan untuk dipasang langsung
# ke perangkat tanpa proses signing ulang (mis. Sideloadly, AltStore, atau
# re-sign dengan sertifikat sendiri).
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="TelAerox155.xcodeproj"
SCHEME="TelAerox155"
CONFIGURATION="Release"
DERIVED_DATA="./build"
APP_NAME="TelAerox155"
OUTPUT_IPA="${DERIVED_DATA}/${APP_NAME}.ipa"

echo "==> Build ${APP_NAME} (${CONFIGURATION})"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphoneos/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "error: app tidak ditemukan di ${APP_PATH}" >&2
  exit 1
fi

# secrets.local.json tidak boleh ikut ter-bundle (lihat AGENTS.md). File ini
# sudah dikecualikan dari target di project.pbxproj; periksa sekali lagi.
if [ -f "${APP_PATH}/secrets.local.json" ]; then
  echo "error: secrets.local.json ikut ter-bundle ke dalam app. Batalkan pengemasan IPA." >&2
  exit 1
fi

echo "==> Kemas IPA"
rm -rf "${DERIVED_DATA}/ipa"
mkdir -p "${DERIVED_DATA}/ipa/Payload"
cp -R "$APP_PATH" "${DERIVED_DATA}/ipa/Payload/"
rm -f "$OUTPUT_IPA"
( cd "${DERIVED_DATA}/ipa" && zip -qry "../${APP_NAME}.ipa" Payload )
rm -rf "${DERIVED_DATA}/ipa"

echo "==> Selesai: ${OUTPUT_IPA}"
ls -lh "$OUTPUT_IPA"
