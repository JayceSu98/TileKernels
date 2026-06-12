#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./run_cutedsl_tests.sh [all|correctness|benchmark] [options] [-- extra pytest args]

Modes:
  all          Run correctness + benchmark together. This is the default.
  correctness  Run correctness only.
  benchmark    Run benchmark cases only.

Options:
  -n, --workers N         Pytest xdist worker count. Default: 2
  --tilelang-dir PATH     Local TileLang checkout. Default: $TILELANG_DIR or ../tilelang
  --python PATH           Python executable. Default: ./.venv-tk-test/bin/python
  -h, --help              Show this help

Environment overrides:
  TK_CUDA_VISIBLE_DEVICES     Visible GPU list for this host. Default: $CUDA_VISIBLE_DEVICES or 0
  TK_BENCHMARK_BACKEND        Benchmark timer backend. Default: event
  TK_FULL_TEST                Full parameter coverage flag. Default: 1
  TILELANG_DISABLE_CACHE      TileLang cache toggle. Default: 1
  TK_BUILD_JOBS               TileLang build jobs. Default: 16
  TK_SKIP_BUILD               Skip `cmake --build` when set to 1

Examples:
  ./run_cutedsl_tests.sh
  ./run_cutedsl_tests.sh correctness
  ./run_cutedsl_tests.sh benchmark -n 2
  ./run_cutedsl_tests.sh all -- tests/engram/test_engram_fused_weight.py
EOF
}

MODE="all"
WORKERS=2
TILELANG_DIR="${TILELANG_DIR:-}"
PYTHON_BIN=""
EXTRA_PYTEST_ARGS=()

while (($#)); do
  case "$1" in
    all|correctness|benchmark)
      MODE="$1"
      shift
      ;;
    -n|--workers)
      WORKERS="$2"
      shift 2
      ;;
    --tilelang-dir)
      TILELANG_DIR="$2"
      shift 2
      ;;
    --python)
      PYTHON_BIN="$2"
      shift 2
      ;;
    --)
      shift
      EXTRA_PYTEST_ARGS+=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      EXTRA_PYTEST_ARGS+=("$1")
      shift
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${PYTHON_BIN}" ]]; then
  PYTHON_BIN="${ROOT_DIR}/.venv-tk-test/bin/python"
fi
if [[ -z "${TILELANG_DIR}" ]]; then
  TILELANG_DIR="${ROOT_DIR}/../tilelang"
fi

if [[ ! -x "${PYTHON_BIN}" ]]; then
  echo "[error] Python executable not found: ${PYTHON_BIN}" >&2
  exit 1
fi
if [[ ! -d "${TILELANG_DIR}" ]]; then
  echo "[error] TileLang directory not found: ${TILELANG_DIR}" >&2
  exit 1
fi
TILELANG_DIR="$(cd "${TILELANG_DIR}" && pwd)"

CUDA_VISIBLE_DEVICES_VALUE="${TK_CUDA_VISIBLE_DEVICES:-${CUDA_VISIBLE_DEVICES:-0}}"
BENCHMARK_BACKEND_VALUE="${TK_BENCHMARK_BACKEND:-event}"
FULL_TEST_VALUE="${TK_FULL_TEST:-1}"
DISABLE_CACHE_VALUE="${TILELANG_DISABLE_CACHE:-1}"
BUILD_JOBS_VALUE="${TK_BUILD_JOBS:-16}"
SKIP_BUILD_VALUE="${TK_SKIP_BUILD:-0}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"

mkdir -p "${ROOT_DIR}/.test-logs"

RUN_LABEL="${MODE}"
LOG_PREFIX="${ROOT_DIR}/.test-logs/${RUN_LABEL}_cutedsl_n${WORKERS}_${BENCHMARK_BACKEND_VALUE}_${STAMP}"
LOG_PATH="${LOG_PREFIX}.log"
JSONL_PATH="${LOG_PREFIX}.jsonl"
FAILURE_PREFIX="${LOG_PREFIX}.failure"
TRACE_PREFIX="${LOG_PREFIX}.trace"
CACHE_DIR="${LOG_PREFIX}.cache"

export PYTHONPATH="${TILELANG_DIR}${PYTHONPATH:+:${PYTHONPATH}}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES_VALUE}"
export TILELANG_TARGET="cutedsl"
export TILELANG_DISABLE_CACHE="${DISABLE_CACHE_VALUE}"
export TK_FULL_TEST="${FULL_TEST_VALUE}"
export TILELANG_CACHE_DIR="${CACHE_DIR}"
export TK_TILELANG_CACHE_PER_WORKER="1"
export TK_BENCHMARK_FAILURE_REPORT="${FAILURE_PREFIX}"
export TK_BENCHMARK_TRACE_REPORT="${TRACE_PREFIX}"

PYTEST_ARGS=(
  tests
  -n "${WORKERS}"
  --tb=short
  -ra
)

case "${MODE}" in
  all)
    export TK_BENCHMARK_BACKEND="${BENCHMARK_BACKEND_VALUE}"
    export TK_BENCHMARK_ALLOW_MISSING_BASELINES="1"
    PYTEST_ARGS+=(
      --run-benchmark
      "--benchmark-output=${JSONL_PATH}"
    )
    ;;
  correctness)
    ;;
  benchmark)
    export TK_BENCHMARK_BACKEND="${BENCHMARK_BACKEND_VALUE}"
    export TK_BENCHMARK_ALLOW_MISSING_BASELINES="1"
    PYTEST_ARGS+=(
      --run-benchmark
      -m benchmark
      "--benchmark-output=${JSONL_PATH}"
    )
    ;;
esac

if ((${#EXTRA_PYTEST_ARGS[@]})); then
  PYTEST_ARGS+=("${EXTRA_PYTEST_ARGS[@]}")
fi

echo "[run] mode=${MODE}"
echo "[run] workers=${WORKERS}"
echo "[run] tilelang_dir=${TILELANG_DIR}"
echo "[run] python=${PYTHON_BIN}"
echo "[run] CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}"
echo "[run] log=${LOG_PATH}"
if [[ "${MODE}" != "correctness" ]]; then
  echo "[run] benchmark_jsonl=${JSONL_PATH}"
fi

"${PYTHON_BIN}" - <<'PY'
import os
import torch

print(f"[env] CUDA_VISIBLE_DEVICES={os.environ.get('CUDA_VISIBLE_DEVICES')}")
print(f"[env] torch.cuda.device_count()={torch.cuda.device_count()}")
for idx in range(torch.cuda.device_count()):
    print(f"[env] cuda:{idx} -> {torch.cuda.get_device_name(idx)}")
PY

if [[ "${SKIP_BUILD_VALUE}" != "1" ]]; then
  echo "[build] cmake --build ${TILELANG_DIR}/build -j ${BUILD_JOBS_VALUE}"
  cmake --build "${TILELANG_DIR}/build" -j "${BUILD_JOBS_VALUE}"
fi

echo "[pytest] ${PYTHON_BIN} -m pytest ${PYTEST_ARGS[*]}"
"${PYTHON_BIN}" -m pytest "${PYTEST_ARGS[@]}" 2>&1 | tee "${LOG_PATH}"
