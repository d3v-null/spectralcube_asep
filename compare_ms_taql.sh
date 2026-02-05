#!/usr/bin/env bash
set -euo pipefail
TAQL=/opt/view/bin/taql
STYLE=(-s glish)

A="${1:?msA}"
B="${2:?msB}"

show_one() {
  local ms="$1"
  echo "===== $ms ====="
  $TAQL "${STYLE[@]}" "show table $ms" | sed -n '1,120p' || true
  echo

  echo "-- basic"
  $TAQL "${STYLE[@]}" -p "select countall() as nrows from $ms" || true
  $TAQL "${STYLE[@]}" -p "select gfirst(shape(DATA)) as data_shape from $ms" || true
  echo

  echo "-- SPECTRAL_WINDOW"
  $TAQL "${STYLE[@]}" -p "select countall() as nspw from $ms/SPECTRAL_WINDOW" || true
  $TAQL "${STYLE[@]}" -p "select gfirst(NUM_CHAN) as num_chan, gfirst(CHAN_FREQ) as chan_freq0 from $ms/SPECTRAL_WINDOW" || true
  echo

  echo "-- FIELD"
  $TAQL "${STYLE[@]}" -p "select countall() as nfield from $ms/FIELD" || true
  $TAQL "${STYLE[@]}" -p "select gfirst(NAME) as field_name, gfirst(DELAY_DIR) as delay_dir, gfirst(PHASE_DIR) as phase_dir from $ms/FIELD" || true
  echo

  echo "-- HISTORY"
  $TAQL "${STYLE[@]}" -p "select countall() as nhist from $ms/HISTORY" || true
  echo

  echo "-- sample rows"
  $TAQL "${STYLE[@]}" -p "select TIME,ANTENNA1,ANTENNA2,DATA[1,1],DATA[1,2] from $ms limit 3" || true
  echo
}

show_one "$A"
show_one "$B"

# Compare some numeric summaries
sumstats() {
  local ms="$1" label="$2"
  echo "===== STATS $label ====="
  $TAQL "${STYLE[@]}" -p "select gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from $ms" || true
  if $TAQL "${STYLE[@]}" -noprintselect "select FLAG from $ms limit 0" >/dev/null 2>&1; then
    $TAQL "${STYLE[@]}" -p "select gsum(ntrue(FLAG)) as nflag_true, gsum(nfalse(FLAG)) as nflag_false, gsum(ntrue(FLAG))/(gsum(ntrue(FLAG))+gsum(nfalse(FLAG))) as frac_flag from $ms" || true
  fi
  echo
}

sumstats "$A" A
sumstats "$B" B
