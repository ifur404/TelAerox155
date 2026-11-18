#!/bin/bash
# Publish TelAerox155 ke production di Sideload Upkan (https://sideload.upkan.id).
#
# Panduan lengkap: docs/publish-production.md
#
# Pemakaian:
#   bash scripts/publish-sideload.sh --changelog "Perbaikan koneksi BLE"
#   bash scripts/publish-sideload.sh --skip-build --changelog "..."   # pakai build/TelAerox155.ipa yang ada
#   bash scripts/publish-sideload.sh --listing-only                   # perbarui listing saja, tanpa IPA
#
# Opsi tambahan: --changelog-file FILE, --ipa PATH, --screenshots DIR, --ipad-screenshots DIR, --icon FILE
#
# Upload dilakukan oleh CLI resmi scripts/publish.mjs (multipart + retry) dengan metadata listing dari
# scripts/sideload.json. API key dibaca dari .env (SIDELOAD_KEY=upk_...). File .env diabaikan Git;
# jangan pernah mencetak atau meng-commit isinya.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.rupi.TelAerox155"
METADATA="scripts/sideload.json"
IPA_PATH="build/TelAerox155.ipa"
CHANGELOG=""
SKIP_BUILD=0
LISTING_ONLY=0
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --changelog) CHANGELOG="${2:-}"; shift 2 ;;
    --changelog-file) CHANGELOG="$(cat "${2:?path changelog wajib}")"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --listing-only) LISTING_ONLY=1; shift ;;
    --ipa) IPA_PATH="${2:?path IPA wajib}"; shift 2 ;;
    --screenshots|--ipad-screenshots|--icon) EXTRA_ARGS+=("$1" "${2:?$1 butuh path}"); shift 2 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "error: argumen tidak dikenal: $1" >&2; exit 2 ;;
  esac
done

# Muat SIDELOAD_KEY/SIDELOAD_URL dari .env tanpa menampilkan nilainya (dipakai juga oleh publish.mjs).
if [ -z "${SIDELOAD_KEY:-}" ] && [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
API_BASE="${SIDELOAD_URL:-https://sideload.upkan.id}"
API_BASE="${API_BASE%/}"

if [ -z "${SIDELOAD_KEY:-}" ]; then
  echo "error: SIDELOAD_KEY tidak ditemukan. Tambahkan 'SIDELOAD_KEY=upk_...' ke .env di root repo." >&2
  exit 1
fi
case "$SIDELOAD_KEY" in
  upk_*) ;;
  *) echo "error: SIDELOAD_KEY harus diawali 'upk_'." >&2; exit 1 ;;
esac

if [ "$LISTING_ONLY" -eq 0 ] && [ -z "$CHANGELOG" ]; then
  echo "error: changelog wajib diisi (--changelog \"...\" atau --changelog-file FILE)." >&2
  exit 2
fi

command -v node >/dev/null || { echo "error: Node.js 18+ diperlukan untuk scripts/publish.mjs." >&2; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 18 ]; then
  echo "error: Node.js 18+ diperlukan (terpasang: $(node -v))." >&2
  exit 1
fi
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$METADATA" \
  || { echo "error: ${METADATA} bukan JSON yang valid." >&2; exit 1; }

echo "==> Cek API key"
ME_STATUS="$(curl -sS -o /dev/null -w '%{http_code}' "${API_BASE}/api/v1/me" \
  -H "Authorization: Bearer ${SIDELOAD_KEY}")"
if [ "$ME_STATUS" != "200" ]; then
  echo "error: API key ditolak (HTTP ${ME_STATUS}). Buat key baru di ${API_BASE}/dashboard/keys." >&2
  exit 1
fi

if [ "$LISTING_ONLY" -eq 1 ]; then
  echo "==> Perbarui listing ${BUNDLE_ID}"
  node scripts/publish.mjs --bundle-id "$BUNDLE_ID" --metadata "$METADATA" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
  exit 0
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

echo "==> Upload $(basename "$IPA_PATH") ke ${API_BASE}"
node scripts/publish.mjs "$IPA_PATH" \
  --metadata "$METADATA" \
  --changelog "$CHANGELOG" \
  ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
echo "Versi baru menunggu review admin bila status 'pending'; versi lama tetap live sampai disetujui."
