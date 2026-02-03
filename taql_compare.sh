#!/usr/bin/env bash
set -euo pipefail
A="${1:?msA}"
B="${2:?msB}"
TAQL=/opt/view/bin/taql
STYLE=( -s glish )

basic() {
  local ms="$1"
  echo "== $ms"
  $TAQL "${STYLE[@]}" -p "select countall() as nrows from $ms"
  echo
}

stats_col() {
  local ms="$1" col="$2"
  echo "-- $col stats"
  # abs() on complex gives amplitude. DATA-like columns are arrays, so reduce per-row then aggregate across rows.
  $TAQL "${STYLE[@]}" -p "select countall() as nrows, gsum(sum(abs($col))) as sum_abs, gmean(mean(abs($col))) as mean_abs from $ms"
  echo
}

flag_stats() {
  local ms="$1"
  echo "-- FLAG fraction (true elements / total elements)"
  $TAQL "${STYLE[@]}" -p "select gsum(ntrue(FLAG)) as nflag_true, gsum(nfalse(FLAG)) as nflag_false, gsum(ntrue(FLAG))+gsum(nfalse(FLAG)) as nflag_total, gsum(ntrue(FLAG))/(gsum(ntrue(FLAG))+gsum(nfalse(FLAG))) as frac_flag from $ms"
  echo
}

# Basic counts
basic "$A"
basic "$B"

# Compare common data columns
for col in DATA MODEL_DATA CORRECTED_DATA; do
  # If the column exists, the query will work; otherwise taql will error.
  if $TAQL "${STYLE[@]}" -noprintselect "select $col from $A limit 0" >/dev/null 2>&1 && \
     $TAQL "${STYLE[@]}" -noprintselect "select $col from $B limit 0" >/dev/null 2>&1; then
    echo "==== Comparing column $col ===="
    stats_col "$A" "$col"
    stats_col "$B" "$col"
  fi
done

# Compare flag fraction if present
if $TAQL "${STYLE[@]}" -noprintselect "select FLAG from $A limit 0" >/dev/null 2>&1 && \
   $TAQL "${STYLE[@]}" -noprintselect "select FLAG from $B limit 0" >/dev/null 2>&1; then
  echo "==== Comparing FLAG ===="
  flag_stats "$A"
  flag_stats "$B"
fi
