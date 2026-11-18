#!/bin/bash
# Publish TelAerox155 ke production di Sideload Upkan (https://sideload.upkan.id).
#
# Panduan lengkap: docs/publish-production.md
#
# Pemakaian:
#   bash scripts/publish-sideload.sh --changelog "Perbaikan koneksi BLE"
#   bash scripts/publish-sideload.sh --skip-build --changelog "..."   # pakai build/TelAerox155.ipa yang ada
#
# API key dibaca dari .env (variabel SIDELOAD_KEY, format upk_...). File .env diabaikan Git;
# jangan pernah mencetak atau meng-commit isinya.
set -euo pipefail
cd "$(dirname "$0")/.."

API_BASE="${SIDELOAD_URL:-https://sideload.upkan.id}"
IPA_PATH="build/TelAerox155.ipa"
MAX_SINGLE_BYTES=$((95 * 1024 * 1024))
CHANGELOG=""
SKIP_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --changelog) CHANGELOG="${2:-}"; shift 2 ;;
    --changelog-file) CHANGELOG="$(cat "${2:?path changelog wajib}")"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --ipa) IPA_PATH="${2:?path IPA wajib}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "error: argumen tidak dikenal: $1" >&2; exit 2 ;;
  esac
done

# Muat SIDELOAD_KEY dari .env tanpa menampilkan nilainya.
if [ -z "${SIDELOAD_KEY:-}" ] && [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
if [ -z "${SIDELOAD_KEY:-}" ]; then
  echo "error: SIDELOAD_KEY tidak ditemukan. Tambahkan 'SIDELOAD_KEY=upk_...' ke .env di root repo." >&2
  exit 1
fi
case "$SIDELOAD_KEY" in
  upk_*) ;;
  *) echo "error: SIDELOAD_KEY harus diawali 'upk_'." >&2; exit 1 ;;
esac

if [ -z "$CHANGELOG" ]; then
  echo "error: changelog wajib diisi (--changelog \"...\" atau --changelog-file FILE)." >&2
  exit 2
fi

command -v jq >/dev/null || { echo "error: jq diperlukan (brew install jq)." >&2; exit 1; }

AUTH_HEADER="Authorization: Bearer ${SIDELOAD_KEY}"

echo "==> Cek API key"
ME_RESPONSE="$(curl -sS -w '\n%{http_code}' "${API_BASE}/api/v1/me" -H "$AUTH_HEADER")"
ME_STATUS="${ME_RESPONSE##*$'\n'}"
if [ "$ME_STATUS" != "200" ]; then
  echo "error: API key ditolak (HTTP ${ME_STATUS}): ${ME_RESPONSE%$'\n'*}" >&2
  exit 1
fi

if [ "$SKIP_BUILD" -eq 0 ]; then
  bash scripts/build-ipa.sh
fi

if [ ! -f "$IPA_PATH" ]; then
  echo "error: IPA tidak ditemukan di ${IPA_PATH}. Jalankan tanpa --skip-build." >&2
  exit 1
fi

# Pengaman tambahan: kredensial kendaraan tidak boleh ikut ter-upload (lihat AGENTS.md).
if unzip -l "$IPA_PATH" | grep -q 'secrets.local.json'; then
  echo "error: secrets.local.json ada di dalam IPA. Upload dibatalkan." >&2
  exit 1
fi

IPA_SIZE=$(stat -f%z "$IPA_PATH")
if [ "$IPA_SIZE" -gt "$MAX_SINGLE_BYTES" ]; then
  echo "error: IPA ${IPA_SIZE} byte melebihi batas 95 MB untuk upload satu request." >&2
  echo "       Gunakan publish.mjs (multipart), lihat docs/publish-production.md." >&2
  exit 1
fi

echo "==> Upload $(basename "$IPA_PATH") ($(du -h "$IPA_PATH" | cut -f1)) ke ${API_BASE}"
ENCODED_CHANGELOG="$(printf %s "$CHANGELOG" | jq -sRr @uri)"
RESPONSE="$(curl -sS -w '\n%{http_code}' -X POST \
  "${API_BASE}/api/v1/publish?filename=$(basename "$IPA_PATH")" \
  -H "$AUTH_HEADER" \
  -H "Content-Type: application/octet-stream" \
  -H "X-Changelog: ${ENCODED_CHANGELOG}" \
  --data-binary "@${IPA_PATH}")"
STATUS="${RESPONSE##*$'\n'}"
BODY="${RESPONSE%$'\n'*}"

if [ "${STATUS:0:1}" != "2" ]; then
  echo "error: publish gagal (HTTP ${STATUS}):" >&2
  printf '%s\n' "$BODY" | jq . 2>/dev/null >&2 || printf '%s\n' "$BODY" >&2
  exit 1
fi

echo "==> Berhasil (HTTP ${STATUS})"
printf '%s\n' "$BODY" | jq . 2>/dev/null || printf '%s\n' "$BODY"
echo "Versi baru menunggu review admin bila status 'pending'; versi lama tetap live sampai disetujui."
