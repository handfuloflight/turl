#!/usr/bin/env bash
set -euo pipefail

# Local Codex regression checks for turl:
# 1) Real-session soak over ~/.codex/sessions
# 2) Fault-injection checks in isolated temp CODEX_HOME
#
# Usage:
#   scripts/test-codex-local.sh
#   TURL_BIN=/path/to/turl scripts/test-codex-local.sh

TURL_BIN="${TURL_BIN:-}"
if [[ -z "${TURL_BIN}" ]]; then
  if command -v turl >/dev/null 2>&1; then
    TURL_BIN="$(command -v turl)"
  else
    echo "error: turl not found on PATH; set TURL_BIN=/path/to/turl"
    exit 1
  fi
fi

if [[ ! -x "${TURL_BIN}" ]]; then
  echo "error: TURL_BIN is not executable: ${TURL_BIN}"
  exit 1
fi

REAL_ROOT="${HOME}/.codex/sessions"
if [[ ! -d "${REAL_ROOT}" ]]; then
  echo "error: real codex sessions root not found: ${REAL_ROOT}"
  exit 1
fi

WORK_ROOT="$(mktemp -d /tmp/turl-codex-regression-XXXXXX)"
SOAK_ROOT="${WORK_ROOT}/soak"
FAULT_ROOT="${WORK_ROOT}/fault"
mkdir -p "${SOAK_ROOT}" "${FAULT_ROOT}"

echo "turl_bin=${TURL_BIN}"
echo "work_root=${WORK_ROOT}"

soak_summary="${SOAK_ROOT}/summary.tsv"
printf "id\tmd_exit\traw_exit\tdl_exit\teq\tmd_warn\traw_warn\tdl_warn\tmd_lines\traw_lines\n" > "${soak_summary}"

mapfile -t real_files < <(find "${REAL_ROOT}" -type f -name 'rollout-*.jsonl' | sort)
session_count="${#real_files[@]}"
if [[ "${session_count}" -eq 0 ]]; then
  echo "error: no codex rollout files found under ${REAL_ROOT}"
  exit 1
fi

ok_md=0
ok_raw=0
ok_dl=0
ok_eq=0
warn_md=0
warn_raw=0
warn_dl=0

for src in "${real_files[@]}"; do
  id="$(basename "${src}" | sed -E 's/^rollout-[0-9-]+T[0-9-]+-([0-9a-f-]{36})\.jsonl$/\1/')"

  set +e
  "${TURL_BIN}" "codex://${id}" > "${SOAK_ROOT}/${id}.md" 2> "${SOAK_ROOT}/${id}.md.err"
  md_ec=$?
  "${TURL_BIN}" "codex://${id}" --raw > "${SOAK_ROOT}/${id}.raw" 2> "${SOAK_ROOT}/${id}.raw.err"
  raw_ec=$?
  "${TURL_BIN}" "codex://threads/${id}" > "${SOAK_ROOT}/${id}.dl.md" 2> "${SOAK_ROOT}/${id}.dl.err"
  dl_ec=$?
  set -e

  md_warn_bytes="$(wc -c < "${SOAK_ROOT}/${id}.md.err")"
  raw_warn_bytes="$(wc -c < "${SOAK_ROOT}/${id}.raw.err")"
  dl_warn_bytes="$(wc -c < "${SOAK_ROOT}/${id}.dl.err")"

  eq=0
  if [[ "${md_ec}" -eq 0 && "${dl_ec}" -eq 0 ]]; then
    sed '/^- URI:/d' "${SOAK_ROOT}/${id}.md" > "${SOAK_ROOT}/${id}.md.no_uri"
    sed '/^- URI:/d' "${SOAK_ROOT}/${id}.dl.md" > "${SOAK_ROOT}/${id}.dl.no_uri"
    if cmp -s "${SOAK_ROOT}/${id}.md.no_uri" "${SOAK_ROOT}/${id}.dl.no_uri"; then
      eq=1
    fi
  fi

  [[ "${md_ec}" -eq 0 ]] && ok_md=$((ok_md + 1))
  [[ "${raw_ec}" -eq 0 ]] && ok_raw=$((ok_raw + 1))
  [[ "${dl_ec}" -eq 0 ]] && ok_dl=$((ok_dl + 1))
  [[ "${eq}" -eq 1 ]] && ok_eq=$((ok_eq + 1))

  [[ "${md_warn_bytes}" -gt 0 ]] && warn_md=$((warn_md + 1))
  [[ "${raw_warn_bytes}" -gt 0 ]] && warn_raw=$((warn_raw + 1))
  [[ "${dl_warn_bytes}" -gt 0 ]] && warn_dl=$((warn_dl + 1))

  md_lines="$(wc -l < "${SOAK_ROOT}/${id}.md" 2>/dev/null || echo 0)"
  raw_lines="$(wc -l < "${SOAK_ROOT}/${id}.raw" 2>/dev/null || echo 0)"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "${id}" "${md_ec}" "${raw_ec}" "${dl_ec}" "${eq}" \
    "${md_warn_bytes}" "${raw_warn_bytes}" "${dl_warn_bytes}" \
    "${md_lines}" "${raw_lines}" >> "${soak_summary}"
done

echo
echo "[soak]"
echo "sessions=${session_count}"
echo "ok_md=${ok_md} ok_raw=${ok_raw} ok_deeplink=${ok_dl} ok_equivalence=${ok_eq}"
echo "warn_md=${warn_md} warn_raw=${warn_raw} warn_deeplink=${warn_dl}"

echo
echo "[soak_nonzero_or_warn]"
awk -F '\t' 'NR==1{next} ($2!=0 || $3!=0 || $4!=0 || $5!=1 || $6>0 || $7>0 || $8>0){print}' "${soak_summary}" || true

# Fault injection setup from last 3 real sessions
mapfile -t seeds < <(printf "%s\n" "${real_files[@]}" | tail -n 3)
seed_home="${FAULT_ROOT}/home"
mkdir -p "${seed_home}/sessions"
for src in "${seeds[@]}"; do
  rel="${src#${REAL_ROOT}/}"
  dst="${seed_home}/sessions/${rel}"
  mkdir -p "$(dirname "${dst}")"
  cp "${src}" "${dst}"
done

sid_from_rollout() {
  basename "$1" | sed -E 's/^rollout-[0-9-]+T[0-9-]+-([0-9a-f-]{36})\.jsonl$/\1/'
}

f1="${seed_home}/sessions/${seeds[0]#${REAL_ROOT}/}"
f2="${seed_home}/sessions/${seeds[1]#${REAL_ROOT}/}"
f3="${seed_home}/sessions/${seeds[2]#${REAL_ROOT}/}"
s1="$(sid_from_rollout "${f1}")"
s2="$(sid_from_rollout "${f2}")"
s3="$(sid_from_rollout "${f3}")"

# Baseline sanity on copied files
set +e
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s1}" > "${FAULT_ROOT}/baseline1.md" 2> "${FAULT_ROOT}/baseline1.err"; b1=$?
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s2}" > "${FAULT_ROOT}/baseline2.md" 2> "${FAULT_ROOT}/baseline2.err"; b2=$?
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s3}" --raw > "${FAULT_ROOT}/baseline3.raw" 2> "${FAULT_ROOT}/baseline3.err"; b3=$?
set -e

# Fault 1: malformed json line in middle
python3 - <<'PY' "${f1}"
from pathlib import Path
import sys
p = Path(sys.argv[1])
lines = p.read_text(encoding="utf-8", errors="strict").splitlines()
idx = max(1, len(lines) // 2)
lines.insert(idx, "{this is not valid json}")
p.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
set +e
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s1}" > "${FAULT_ROOT}/f1.md" 2> "${FAULT_ROOT}/f1.md.err"; f1_md=$?
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s1}" --raw > "${FAULT_ROOT}/f1.raw" 2> "${FAULT_ROOT}/f1.raw.err"; f1_raw=$?
set -e

# Fault 2: empty file
: > "${f2}"
set +e
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s2}" > "${FAULT_ROOT}/f2.md" 2> "${FAULT_ROOT}/f2.md.err"; f2_md=$?
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s2}" --raw > "${FAULT_ROOT}/f2.raw" 2> "${FAULT_ROOT}/f2.raw.err"; f2_raw=$?
set -e

# Fault 3: non-utf8 file
printf '\377\376\375\374' > "${f3}"
set +e
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s3}" > "${FAULT_ROOT}/f3.md" 2> "${FAULT_ROOT}/f3.md.err"; f3_md=$?
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${s3}" --raw > "${FAULT_ROOT}/f3.raw" 2> "${FAULT_ROOT}/f3.raw.err"; f3_raw=$?
set -e

# Fault 4: missing id
missing="00000000-0000-0000-0000-000000000000"
set +e
CODEX_HOME="${seed_home}" "${TURL_BIN}" "codex://${missing}" > "${FAULT_ROOT}/f4.out" 2> "${FAULT_ROOT}/f4.err"; f4=$?
set -e

echo
echo "[fault]"
echo "baseline_ec: b1=${b1} b2=${b2} b3=${b3}"
echo "f1_malformed: md_ec=${f1_md} raw_ec=${f1_raw}"
echo "f2_empty: md_ec=${f2_md} raw_ec=${f2_raw}"
echo "f3_nonutf8: md_ec=${f3_md} raw_ec=${f3_raw}"
echo "f4_missing: ec=${f4}"

echo
echo "[fault_assertions]"
grep -qi "invalid json line" "${FAULT_ROOT}/f1.md.err" && echo "f1 markdown invalid-json: OK" || echo "f1 markdown invalid-json: FAIL"
[[ "$(wc -c < "${FAULT_ROOT}/f1.raw.err")" -eq 0 ]] && echo "f1 raw no-error: OK" || echo "f1 raw no-error: FAIL"
grep -qi "thread file is empty" "${FAULT_ROOT}/f2.md.err" && grep -qi "thread file is empty" "${FAULT_ROOT}/f2.raw.err" && echo "f2 empty errors: OK" || echo "f2 empty errors: FAIL"
grep -qi "not valid UTF-8" "${FAULT_ROOT}/f3.md.err" && grep -qi "not valid UTF-8" "${FAULT_ROOT}/f3.raw.err" && echo "f3 non-utf8 errors: OK" || echo "f3 non-utf8 errors: FAIL"
grep -qi "thread not found" "${FAULT_ROOT}/f4.err" && echo "f4 not-found: OK" || echo "f4 not-found: FAIL"

echo
echo "artifacts=${WORK_ROOT}"
