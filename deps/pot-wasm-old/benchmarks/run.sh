#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WASM_DEFAULT="$ROOT/examples/bench.wasm"
POT_DEFAULT="$ROOT/po.t"
POT_LEGACY_DEFAULT="$ROOT/pot"

RUNS=7
WARMUPS=1
WASM="$WASM_DEFAULT"
RUNTIMES_CSV="pot,wasmtime,wasmer"
SKIP_CHECKS=0
RAW_DIR=""
QUIET=0

usage() {
  cat <<'EOF'
Usage: benchmarks/run.sh [options]

Options:
  -n, --runs N           Timed runs per runtime (default: 7)
  -w, --warmups N        Warmup runs per runtime (default: 1)
  --wasm PATH            WASM benchmark module (default: examples/bench.wasm)
  --runtimes LIST        Comma list: pot,wasmtime,wasmer (default: all three)
  --skip-checks          Skip checksum/name consistency checks
  --raw-dir DIR          Keep raw per-run files in DIR
  -q, --quiet            Reduce progress output
  -h, --help             Show this help
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$*"
  fi
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

float_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

calc_stats() {
  sort -n | awk '
    {
      a[++n] = $1
      sum += $1
    }
    END {
      if (n == 0) exit 2
      min = a[1]
      max = a[n]
      if (n % 2 == 1) med = a[(n + 1) / 2]
      else med = (a[n / 2] + a[n / 2 + 1]) / 2.0
      mean = sum / n
      var = 0
      for (i = 1; i <= n; i++) {
        d = a[i] - mean
        var += d * d
      }
      if (n > 1) sd = sqrt(var / (n - 1))
      else sd = 0
      if (mean != 0) cv = (sd / mean) * 100.0
      else cv = 0
      printf "%.6f %.6f %.6f %.6f %.6f\n", med, min, max, mean, cv
    }'
}

parse_output_to_tsv() {
  awk '
    {
      if (match($0, /^  (.+)[[:space:]]+(-?[0-9]+)[[:space:]]+us([[:space:]]+\((-?[0-9]+)\))?$/, m)) {
        name = m[1]
        us = m[2]
        result = m[4]
        print name "\t" us "\t" result
        found = 1
      }
    }
    END {
      if (!found) exit 3
    }'
}

runtime_available() {
  local rt="$1"
  case "$rt" in
    pot)
      [[ -x "$POT_DEFAULT" ]] || [[ -x "$POT_LEGACY_DEFAULT" ]] || command -v po.t >/dev/null 2>&1 || command -v pot >/dev/null 2>&1
      ;;
    wasmtime)
      command -v wasmtime >/dev/null 2>&1
      ;;
    wasmer)
      command -v wasmer >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

declare -A RUNTIME_MODE

run_runtime_capture() {
  local rt="$1"
  local __out_ref="$2"
  local __wall_ref="$3"
  local out rc mode
  local start_ns end_ns

  start_ns="$(date +%s%N)"
  rc=1

  case "$rt" in
    pot)
      mode="${RUNTIME_MODE[pot]:-unknown}"
      if [[ "$mode" == "unknown" ]]; then
        if [[ -x "$POT_DEFAULT" ]]; then
          mode="$POT_DEFAULT"
        elif [[ -x "$POT_LEGACY_DEFAULT" ]]; then
          mode="$POT_LEGACY_DEFAULT"
        elif command -v po.t >/dev/null 2>&1; then
          mode="po.t"
        elif command -v pot >/dev/null 2>&1; then
          mode="pot"
        else
          return 127
        fi
        RUNTIME_MODE[pot]="$mode"
      fi
      set +e
      out="$("$mode" "$WASM" 2>&1)"
      rc=$?
      set -e
      ;;
    wasmtime)
      if ! command -v wasmtime >/dev/null 2>&1; then
        return 127
      fi
      mode="${RUNTIME_MODE[wasmtime]:-unknown}"
      if [[ "$mode" == "run" ]]; then
        set +e
        out="$(wasmtime run "$WASM" 2>&1)"
        rc=$?
        set -e
      elif [[ "$mode" == "plain" ]]; then
        set +e
        out="$(wasmtime "$WASM" 2>&1)"
        rc=$?
        set -e
      else
        set +e
        out="$(wasmtime run "$WASM" 2>&1)"
        rc=$?
        set -e
        if [[ "$rc" -eq 0 ]]; then
          RUNTIME_MODE[wasmtime]="run"
        else
          set +e
          out="$(wasmtime "$WASM" 2>&1)"
          rc=$?
          set -e
          if [[ "$rc" -eq 0 ]]; then
            RUNTIME_MODE[wasmtime]="plain"
          fi
        fi
      fi
      ;;
    wasmer)
      if ! command -v wasmer >/dev/null 2>&1; then
        return 127
      fi
      set +e
      out="$(wasmer run "$WASM" 2>&1)"
      rc=$?
      set -e
      ;;
    *)
      return 127
      ;;
  esac

  end_ns="$(date +%s%N)"
  local elapsed_us=$(( (end_ns - start_ns) / 1000 ))

  if [[ "$rc" -ne 0 ]]; then
    echo "$out" >&2
    return "$rc"
  fi

  printf -v "$__out_ref" '%s' "$out"
  printf -v "$__wall_ref" '%s' "$elapsed_us"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--runs)
      [[ $# -ge 2 ]] || die "missing value for $1"
      RUNS="$2"
      shift 2
      ;;
    -w|--warmups)
      [[ $# -ge 2 ]] || die "missing value for $1"
      WARMUPS="$2"
      shift 2
      ;;
    --wasm)
      [[ $# -ge 2 ]] || die "missing value for $1"
      WASM="$2"
      shift 2
      ;;
    --runtimes)
      [[ $# -ge 2 ]] || die "missing value for $1"
      RUNTIMES_CSV="$2"
      shift 2
      ;;
    --skip-checks)
      SKIP_CHECKS=1
      shift
      ;;
    --raw-dir)
      [[ $# -ge 2 ]] || die "missing value for $1"
      RAW_DIR="$2"
      shift 2
      ;;
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

is_integer "$RUNS" || die "--runs must be a non-negative integer"
is_integer "$WARMUPS" || die "--warmups must be a non-negative integer"
[[ "$RUNS" -ge 1 ]] || die "--runs must be >= 1"
[[ "$WARMUPS" -ge 0 ]] || die "--warmups must be >= 0"
[[ -f "$WASM" ]] || die "WASM file not found: $WASM"

tmpdir=""
cleanup() {
  if [[ -n "$tmpdir" && -d "$tmpdir" && -z "$RAW_DIR" ]]; then
    rm -rf "$tmpdir"
  fi
}
trap cleanup EXIT

if [[ -n "$RAW_DIR" ]]; then
  mkdir -p "$RAW_DIR"
  tmpdir="$(cd "$RAW_DIR" && pwd)"
else
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/genwasm-bench.XXXXXX")"
fi

IFS=',' read -r -a requested_runtimes <<<"$RUNTIMES_CSV"
declare -a ACTIVE_RUNTIMES=()
for rt in "${requested_runtimes[@]}"; do
  case "$rt" in
    pot|wasmtime|wasmer) ;;
    "") continue ;;
    *) die "unknown runtime: $rt" ;;
  esac
  if runtime_available "$rt"; then
    ACTIVE_RUNTIMES+=("$rt")
  else
    log "skip: runtime '$rt' not available on PATH"
  fi
done

[[ "${#ACTIVE_RUNTIMES[@]}" -gt 0 ]] || die "no requested runtime is available"

log "WASM: $WASM"
log "Runtimes: ${ACTIVE_RUNTIMES[*]}"
log "Warmups: $WARMUPS  Runs: $RUNS"
log ""

baseline_check="$tmpdir/baseline.check.tsv"
baseline_full="$tmpdir/baseline.full.tsv"
run_tmp="$tmpdir/current.tsv"
check_tmp="$tmpdir/current.check.tsv"
total_iters=$((WARMUPS + RUNS))

for rt in "${ACTIVE_RUNTIMES[@]}"; do
  log "== $rt =="
  measured_idx=0
  for iter in $(seq 1 "$total_iters"); do
    phase="warmup"
    if [[ "$iter" -gt "$WARMUPS" ]]; then
      phase="run"
      measured_idx=$((measured_idx + 1))
    fi
    log "  $phase $iter/$total_iters"

    output=""
    wall_us=""
    if ! run_runtime_capture "$rt" output wall_us; then
      die "runtime '$rt' failed on $phase $iter"
    fi

    if ! printf "%s\n" "$output" | parse_output_to_tsv >"$run_tmp"; then
      echo "$output" >&2
      die "failed to parse benchmark output for runtime '$rt' on $phase $iter"
    fi

    if [[ "$SKIP_CHECKS" -eq 0 ]]; then
      cut -f1,3 "$run_tmp" >"$check_tmp"
      if [[ ! -f "$baseline_check" ]]; then
        cp "$check_tmp" "$baseline_check"
        cp "$run_tmp" "$baseline_full"
      elif ! cmp -s "$baseline_check" "$check_tmp"; then
        echo "checksum/name mismatch on runtime '$rt' $phase $iter" >&2
        echo "--- expected (name,result) ---" >&2
        cat "$baseline_check" >&2
        echo "--- got (name,result) ---" >&2
        cat "$check_tmp" >&2
        die "benchmark output consistency check failed"
      fi
    elif [[ ! -f "$baseline_full" ]]; then
      cp "$run_tmp" "$baseline_full"
    fi

    if [[ "$iter" -gt "$WARMUPS" ]]; then
      cp "$run_tmp" "$tmpdir/$rt.run$measured_idx.tsv"
      printf "%s\n" "$wall_us" >"$tmpdir/$rt.run$measured_idx.wall"
    fi
  done
  log ""
done

[[ -f "$baseline_full" ]] || die "internal error: missing baseline data"

mapfile -t BENCH_NAMES < <(cut -f1 "$baseline_full")
[[ "${#BENCH_NAMES[@]}" -gt 0 ]] || die "no benchmark rows parsed"

declare -A MED
declare -A MIN
declare -A MAX
declare -A CV
declare -A WALL_MED
declare -A WALL_CV
declare -A INSIDE_MED
declare -A OVERHEAD_MED

for rt in "${ACTIVE_RUNTIMES[@]}"; do
  for bench in "${BENCH_NAMES[@]}"; do
    values="$(awk -F'\t' -v b="$bench" '$1 == b { print $2 }' "$tmpdir"/"$rt".run*.tsv)"
    [[ -n "$values" ]] || die "missing values for $rt / $bench"
    read -r med min max _mean cv <<<"$(printf "%s\n" "$values" | calc_stats)"
    MED["$rt|$bench"]="$med"
    MIN["$rt|$bench"]="$min"
    MAX["$rt|$bench"]="$max"
    CV["$rt|$bench"]="$cv"
  done

  read -r wall_med _wall_min _wall_max _wall_mean wall_cv <<<"$(cat "$tmpdir"/"$rt".run*.wall | calc_stats)"
  WALL_MED["$rt"]="$wall_med"
  WALL_CV["$rt"]="$wall_cv"

  inside_file="$tmpdir/$rt.inside.txt"
  overhead_file="$tmpdir/$rt.overhead.txt"
  : >"$inside_file"
  : >"$overhead_file"
  for i in $(seq 1 "$RUNS"); do
    inside_us="$(awk -F'\t' '{ s += $2 } END { printf "%.0f\n", s + 0 }' "$tmpdir/$rt.run$i.tsv")"
    wall_us="$(cat "$tmpdir/$rt.run$i.wall")"
    printf "%s\n" "$inside_us" >>"$inside_file"
    printf "%s\n" "$(( wall_us - inside_us ))" >>"$overhead_file"
  done
  read -r inside_med _imn _imx _imean _icv <<<"$(cat "$inside_file" | calc_stats)"
  read -r overhead_med _omn _omx _omean _ocv <<<"$(cat "$overhead_file" | calc_stats)"
  INSIDE_MED["$rt"]="$inside_med"
  OVERHEAD_MED["$rt"]="$overhead_med"
done

bench_w=9
for b in "${BENCH_NAMES[@]}"; do
  if [[ "${#b}" -gt "$bench_w" ]]; then
    bench_w="${#b}"
  fi
done

echo "Median per benchmark (us, lower is better)"
printf "%-${bench_w}s" "benchmark"
for rt in "${ACTIVE_RUNTIMES[@]}"; do
  printf "  %12s" "$rt"
done
printf "  %14s\n" "winner"
printf "%-${bench_w}s" "$(printf "%-${bench_w}s" "" | tr ' ' '-')"
for _ in "${ACTIVE_RUNTIMES[@]}"; do
  printf "  %12s" "------------"
done
printf "  %14s\n" "--------------"

for bench in "${BENCH_NAMES[@]}"; do
  best_rt=""
  best_med=""
  second_med=""

  printf "%-${bench_w}s" "$bench"
  for rt in "${ACTIVE_RUNTIMES[@]}"; do
    med="${MED["$rt|$bench"]}"
    printf "  %12s" "$(awk -v m="$med" 'BEGIN { printf "%.0f", m }')"
    if [[ -z "$best_rt" ]]; then
      best_rt="$rt"
      best_med="$med"
      continue
    fi
    if float_lt "$med" "$best_med"; then
      second_med="$best_med"
      best_rt="$rt"
      best_med="$med"
    elif [[ -z "$second_med" ]] || float_lt "$med" "$second_med"; then
      second_med="$med"
    fi
  done

  if [[ -n "$second_med" ]]; then
    speedup="$(awk -v a="$second_med" -v b="$best_med" 'BEGIN { if (b > 0) printf "%.2fx", a / b; else printf "n/a" }')"
  else
    speedup="n/a"
  fi
  printf "  %14s\n" "$best_rt $speedup"
done

echo
echo "Runtime overhead summary (median over runs)"
printf "%-10s  %12s  %12s  %14s  %8s\n" "runtime" "wall(ms)" "in-wasm(ms)" "overhead(ms)" "wall-cv%"
printf "%-10s  %12s  %12s  %14s  %8s\n" "----------" "------------" "------------" "--------------" "--------"
for rt in "${ACTIVE_RUNTIMES[@]}"; do
  wall_ms="$(awk -v u="${WALL_MED[$rt]}" 'BEGIN { printf "%.3f", u / 1000.0 }')"
  inside_ms="$(awk -v u="${INSIDE_MED[$rt]}" 'BEGIN { printf "%.3f", u / 1000.0 }')"
  overhead_ms="$(awk -v u="${OVERHEAD_MED[$rt]}" 'BEGIN { printf "%.3f", u / 1000.0 }')"
  wall_cv="$(awk -v c="${WALL_CV[$rt]}" 'BEGIN { printf "%.2f", c }')"
  printf "%-10s  %12s  %12s  %14s  %8s\n" "$rt" "$wall_ms" "$inside_ms" "$overhead_ms" "$wall_cv"
done

baseline_rt="${ACTIVE_RUNTIMES[0]}"
for rt in "${ACTIVE_RUNTIMES[@]}"; do
  if [[ "$rt" == "pot" ]]; then
    baseline_rt="pot"
    break
  fi
done

echo
echo "Relative speed vs $baseline_rt (geometric mean of per-benchmark medians)"
printf "%-10s  %10s\n" "runtime" "ratio"
printf "%-10s  %10s\n" "----------" "----------"
for rt in "${ACTIVE_RUNTIMES[@]}"; do
  ratio_file="$tmpdir/$rt.ratios.txt"
  : >"$ratio_file"
  for bench in "${BENCH_NAMES[@]}"; do
    base="${MED["$baseline_rt|$bench"]}"
    cur="${MED["$rt|$bench"]}"
    awk -v a="$cur" -v b="$base" 'BEGIN { if (b > 0) printf "%.12f\n", a / b; else print "1.0" }' >>"$ratio_file"
  done
  gmean="$(awk '
    {
      if ($1 <= 0) next
      sum += log($1)
      n++
    }
    END {
      if (n == 0) printf "n/a"
      else printf "%.3f", exp(sum / n)
    }' "$ratio_file")"
  printf "%-10s  %10s\n" "$rt" "${gmean}x"
done

echo
echo "Raw data directory: $tmpdir"
if [[ -z "$RAW_DIR" ]]; then
  echo "(temporary; removed automatically at exit)"
else
  echo "(preserved)"
fi
