#!/usr/bin/env bash
set -euo pipefail

# Compare hyperdrive vis-simulate vs DP3 predict for a single 1 Jy point source
# at multiple sky positions, with and without beam.

obsid=${obsid:-1099487728}
metafits=${metafits:-${obsid}.metafits}
beamfile=${MWA_BEAM_FILE:-mwa_full_embedded_element_pattern.h5}

# Simulation grid settings (match earlier tests)
freq_res_khz=${freq_res_khz:-1280}
num_fine_chans=${num_fine_chans:-24}
time_res_s=${time_res_s:-8}
num_timesteps=${num_timesteps:-1}

OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS:-1}

if ! command -v python3 >/dev/null; then
  echo "python3 missing" >&2
  exit 2
fi

# Extract nominal pointing/zenith from metafits
read -r ra0 dec0 <<<"$(python3 - <<PY
from astropy.io import fits
h=fits.getheader('$metafits')
print(h['RA'], h['DEC'])
PY
)"

# Generate a list of test positions in degrees.
# Offsets are in DEC and RA (RA offset scaled by cos(DEC)).
python3 - <<PY > positions.txt
import math
ra0=float("${ra0}")
dec0=float("${dec0}")
# offsets in degrees
offsets=[0,5,10,20,30]
print(f"center {ra0:.6f} {dec0:.6f}")
for d in offsets[1:]:
    # north/south
    print(f"dec+{d:02d} {ra0:.6f} {dec0+d:.6f}")
    print(f"dec-{d:02d} {ra0:.6f} {dec0-d:.6f}")
    # east/west (approx; good enough for beam sanity)
    dra=d/math.cos(math.radians(dec0))
    print(f"ra+{d:02d} {ra0+dra:.6f} {dec0:.6f}")
    print(f"ra-{d:02d} {ra0-dra:.6f} {dec0:.6f}")
PY

# Helper: write a 1 Jy point-source hyperdrive-format model at given RA/DEC (deg)
write_model () {
  local name=$1
  local ra_deg=$2
  local dec_deg=$3
  local out=$4
  python3 - <<PY > "$out"
from astropy.coordinates import SkyCoord
import astropy.units as u
c=SkyCoord(ra=float('$ra_deg')*u.deg, dec=float('$dec_deg')*u.deg, frame='icrs')
ra_hms=c.ra.to_string(unit=u.hour, sep='hms', pad=True, precision=4)
dec_dms=c.dec.to_string(unit=u.deg, sep='dms', alwayssign=True, pad=True, precision=4)
print('skymodel fileformat 1.1')
print('source {')
print('  name "${name}"')
print('  component {')
print('    type point')
print(f'    position {ra_hms} {dec_dms}')
print('    sed {')
print('      frequency 200 MHz')
print('      fluxdensity Jy 1.0 0 0 0')
print('      spectral-index { 0.0 0.00 }')
print('    }')
print('  }')
print('}')
PY
}

# Helper: convert hyperdrive model -> DP3 skymodel text
convert_to_dp3 () {
  local in_model=$1
  local out_model=$2
  docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
    editmodel -skymodel "$out_model" "$in_model" >/dev/null
}

# Helper: run DP3 predict
run_dp3_predict () {
  local msin=$1
  local msout=$2
  local dp3_model=$3
  local usebeam=$4
  docker run --rm -e OPENBLAS_NUM_THREADS="$OPENBLAS_NUM_THREADS" -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
    msin="$msin" msout="$msout" steps=[predict] \
    predict.sourcedb="$dp3_model" \
    predict.usebeammodel=$usebeam \
    predict.coefficients_path="$beamfile" \
    msout.overwrite=true >/dev/null
}

# Ensure taql_stats.sh exists
if [[ ! -x ./taql_stats.sh ]]; then
  echo "ERROR: taql_stats.sh not found or not executable in $PWD" >&2
  exit 2
fi

mkdir -p one_source_tests

report=one_source_tests/report.tsv
printf "tag\tra_deg\tdec_deg\thyp_no_beam_mean\thyp_beam_mean\tdp3_no_beam_mean\tdp3_beam_mean\tratio_hyp\tratio_dp3\n" > "$report"

while read -r tag ra dec; do
  echo "== $tag (RA=$ra deg, Dec=$dec deg) =="
  base="one_source_tests/${obsid}_${tag}"
  hyp_model="${base}.hyp.txt"
  dp3_model="${base}.dp3.skymodel.txt"

  write_model "TEST_${tag}" "$ra" "$dec" "$hyp_model"
  convert_to_dp3 "$hyp_model" "$dp3_model"

  # Hyperdrive simulate (no beam)
  docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
    --source-dist-cutoff=180 --veto-threshold 0 \
    --freq-res ${freq_res_khz} --num-fine-channels ${num_fine_chans} \
    --time-res ${time_res_s} --num-timesteps ${num_timesteps} \
    --metafits "$metafits" \
    --no-beam \
    --source-list "$hyp_model" \
    --output-model-files "${base}.hyp_nobeam.ms" >/dev/null

  # Hyperdrive simulate (beam)
  docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
    --source-dist-cutoff=180 --veto-threshold 0 \
    --freq-res ${freq_res_khz} --num-fine-channels ${num_fine_chans} \
    --time-res ${time_res_s} --num-timesteps ${num_timesteps} \
    --metafits "$metafits" \
    --beam-file "$beamfile" \
    --source-list "$hyp_model" \
    --output-model-files "${base}.hyp_beam.ms" >/dev/null

  # Fix mwams on hyperdrive MS so DP3 has the best chance of reading MWA metadata
  docker run --rm -v "$PWD:$PWD" -w "$PWD" mwatelescope/cotter fixmwams "${base}.hyp_nobeam.ms" "$metafits" >/dev/null
  docker run --rm -v "$PWD:$PWD" -w "$PWD" mwatelescope/cotter fixmwams "${base}.hyp_beam.ms" "$metafits" >/dev/null

  # DP3 predict, no beam and beam, using the *same* msin
  run_dp3_predict "${base}.hyp_nobeam.ms" "${base}.dp3_nobeam.ms" "$dp3_model" false
  run_dp3_predict "${base}.hyp_nobeam.ms" "${base}.dp3_beam.ms" "$dp3_model" true

  # Stats: mean(|DATA|)
  hyp_no=$(docker run --rm -v "$PWD:$PWD" --entrypoint "$PWD/taql_stats.sh" d3vnull0/dp3-mwa:latest "$PWD/${base}.hyp_nobeam.ms" | awk '(NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.eE+-]+$/ && $3 ~ /^[0-9.eE+-]+$/){v=$3} END{print v}')
  hyp_bm=$(docker run --rm -v "$PWD:$PWD" --entrypoint "$PWD/taql_stats.sh" d3vnull0/dp3-mwa:latest "$PWD/${base}.hyp_beam.ms" | awk '(NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.eE+-]+$/ && $3 ~ /^[0-9.eE+-]+$/){v=$3} END{print v}')
  dp3_no=$(docker run --rm -v "$PWD:$PWD" --entrypoint "$PWD/taql_stats.sh" d3vnull0/dp3-mwa:latest "$PWD/${base}.dp3_nobeam.ms" | awk '(NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.eE+-]+$/ && $3 ~ /^[0-9.eE+-]+$/){v=$3} END{print v}')
  dp3_bm=$(docker run --rm -v "$PWD:$PWD" --entrypoint "$PWD/taql_stats.sh" d3vnull0/dp3-mwa:latest "$PWD/${base}.dp3_beam.ms" | awk '(NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.eE+-]+$/ && $3 ~ /^[0-9.eE+-]+$/){v=$3} END{print v}')

  ratio_h=$(python3 - <<PY
hn=float('$hyp_no'); hb=float('$hyp_bm')
print(hb/hn if hn else float('nan'))
PY
)
  ratio_d=$(python3 - <<PY
dn=float('$dp3_no'); db=float('$dp3_bm')
print(db/dn if dn else float('nan'))
PY
)

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$tag" "$ra" "$dec" "$hyp_no" "$hyp_bm" "$dp3_no" "$dp3_bm" "$ratio_h" "$ratio_d" >> "$report"

done < positions.txt

echo "Wrote $report"
