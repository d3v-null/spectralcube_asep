#!/usr/bin/env bash
set -euo pipefail

# Diagnose DP3 predict vs hyperdrive vis-simulate beam application using a single off-axis source.
# Creates four MSes:
#   hyp_1src_nobeam.ms, hyp_1src_beam.ms
#   dp3_1src_nobeam.ms, dp3_1src_beam.ms
# Then prints mean(|DATA|) and attenuation ratios.

obsid=${obsid:-1099487728}
ms_geom=${ms_geom:-birli_${obsid}_4s_40kHz.ms}
metafits=${metafits:-${obsid}.metafits}
beamfile=${MWA_BEAM_FILE:-mwa_full_embedded_element_pattern.h5}

# Simulation settings (match earlier)
freq_res_khz=${freq_res_khz:-1280}
num_fine_chans=${num_fine_chans:-24}
time_res_s=${time_res_s:-8}
num_timesteps=${num_timesteps:-1}

# Off-axis offset in degrees
OFF_DEG=${OFF_DEG:-10}
# offset mode: ra|dec|both
OFF_MODE=${OFF_MODE:-ra}

# DP3 model (LoFAR/DP3 skymodel text). If not set, we convert with lofartools.
DP3_MODEL=${DP3_MODEL:-}

OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS:-1}

need() { command -v "$1" >/dev/null || { echo "Missing $1" >&2; exit 2; }; }
need python3

for f in "$ms_geom" "$metafits" "$beamfile"; do
  [[ -e "$f" ]] || { echo "Missing required file: $f" >&2; exit 2; }
done

# Phase centre / zenith from metafits header (RA/DEC in degrees)
read -r ra0 dec0 <<<"$(python3 - <<PY
from astropy.io import fits
h=fits.getheader('$metafits')
print(h['RA'], h['DEC'])
PY
)"

# Build off-axis source coord
read -r ra1 dec1 <<<"$(python3 - <<PY
import math
ra0=float('$ra0'); dec0=float('$dec0')
off=float('$OFF_DEG')
mode='$OFF_MODE'
ra,dec=ra0,dec0
if mode in ('ra','both'):
    ra = ra0 + off/math.cos(math.radians(dec0))
if mode in ('dec','both'):
    dec = dec0 + off
print(ra, dec)
PY
)"

outdir=dp3_vs_hyp_1src
mkdir -p "$outdir"

hyp_model_txt="$outdir/1src_offaxis.ao.txt"
dp3_model_txt="$outdir/1src_offaxis.skymodel.txt"

# Write AO/hyperdrive model
python3 - <<PY > "$hyp_model_txt"
from astropy.coordinates import SkyCoord
import astropy.units as u
c=SkyCoord(ra=float('$ra1')*u.deg, dec=float('$dec1')*u.deg, frame='icrs')
ra_hms=c.ra.to_string(unit=u.hour, sep='hms', pad=True, precision=4)
dec_dms=c.dec.to_string(unit=u.deg, sep='dms', alwayssign=True, pad=True, precision=4)
print('skymodel fileformat 1.1')
print('source {')
print('  name "OFFAX_1JY"')
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

# Convert to DP3 skymodel format
if [[ -z "$DP3_MODEL" ]]; then
  docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
    editmodel -skymodel "$dp3_model_txt" "$hyp_model_txt" >/dev/null
  DP3_MODEL="$dp3_model_txt"
fi

hyp_nobeam="$outdir/hyp_1src_nobeam.ms"
hyp_beam="$outdir/hyp_1src_beam.ms"

# Prior runs may have created root-owned MSes (from container tools). Clean with sudo if needed.
if command -v sudo >/dev/null; then
  sudo rm -rf "$hyp_nobeam" "$hyp_beam" "$outdir/dp3_1src_"*.ms "$outdir/dp3_1src_"*.ms 2>/dev/null || true
fi
rm -rf "$hyp_nobeam" "$hyp_beam" "$outdir/dp3_1src_"*.ms 2>/dev/null || true

# Hyperdrive simulate (no beam)
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
  --source-dist-cutoff=180 --veto-threshold 0 \
  --freq-res ${freq_res_khz} --num-fine-channels ${num_fine_chans} \
  --time-res ${time_res_s} --num-timesteps ${num_timesteps} \
  --metafits "$metafits" \
  --no-beam \
  --source-list "$hyp_model_txt" \
  --output-model-files "$hyp_nobeam" >/dev/null

# Hyperdrive simulate (beam)
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
  --source-dist-cutoff=180 --veto-threshold 0 \
  --freq-res ${freq_res_khz} --num-fine-channels ${num_fine_chans} \
  --time-res ${time_res_s} --num-timesteps ${num_timesteps} \
  --metafits "$metafits" \
  --beam-file "$beamfile" \
  --source-list "$hyp_model_txt" \
  --output-model-files "$hyp_beam" >/dev/null

# Fix MWA keywords for DP3/EveryBeam
for m in "$hyp_nobeam" "$hyp_beam"; do
  docker run --rm -v "$PWD:$PWD" -w "$PWD" mwatelescope/cotter fixmwams "$m" "$metafits" >/dev/null
done

# DP3 predict (no beam + beam) in two modes:
#   A) msin = hyperdrive-sim no-beam MS (same geometry as hyp vis-sim)
#   B) msin = the real birli MS (to test whether the simulated MS metadata is the problem)
export OPENBLAS_NUM_THREADS

dp3_nobeam_hypms="$outdir/dp3_1src_nobeam__msin_hyp.ms"
dp3_beam_hypms="$outdir/dp3_1src_beam__msin_hyp.ms"
dp3_nobeam_birlms="$outdir/dp3_1src_nobeam__msin_birli.ms"
dp3_beam_birlms="$outdir/dp3_1src_beam__msin_birli.ms"
rm -rf "$dp3_nobeam_hypms" "$dp3_beam_hypms" "$dp3_nobeam_birlms" "$dp3_beam_birlms"

# A) msin = hyp_nobeam

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin="$hyp_nobeam" msout="$dp3_nobeam_hypms" steps=[predict] \
  predict.sourcedb="$DP3_MODEL" \
  predict.usebeammodel=false \
  msout.overwrite=true >/dev/null

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin="$hyp_nobeam" msout="$dp3_beam_hypms" steps=[predict] \
  predict.sourcedb="$DP3_MODEL" \
  predict.usebeammodel=true \
  predict.coefficients_path="$beamfile" \
  msout.overwrite=true >/dev/null

# B) msin = birli MS

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin="$ms_geom" msout="$dp3_nobeam_birlms" steps=[predict] \
  predict.sourcedb="$DP3_MODEL" \
  predict.usebeammodel=false \
  msout.overwrite=true >/dev/null

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin="$ms_geom" msout="$dp3_beam_birlms" steps=[predict] \
  predict.sourcedb="$DP3_MODEL" \
  predict.usebeammodel=true \
  predict.coefficients_path="$beamfile" \
  msout.overwrite=true >/dev/null

# Stats helper: mean abs from taql_stats output
mean_abs() {
  local ms=$1
  docker run --rm -v "$PWD:$PWD" --entrypoint "$PWD/taql_stats.sh" d3vnull0/dp3-mwa:latest "$PWD/$ms" \
    | awk '(NF==3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9.eE+-]+$/ && $3 ~ /^[0-9.eE+-]+$/){v=$3} END{print v}'
}

hyp_no=$(mean_abs "$hyp_nobeam")
hyp_bm=$(mean_abs "$hyp_beam")

# DP3 stats A) msin=hyp_nobeam
Dp3A_no=$(mean_abs "$dp3_nobeam_hypms")
Dp3A_bm=$(mean_abs "$dp3_beam_hypms")

# DP3 stats B) msin=birli
Dp3B_no=$(mean_abs "$dp3_nobeam_birlms")
Dp3B_bm=$(mean_abs "$dp3_beam_birlms")

ratio_h=$(python3 - <<PY
hn=float('$hyp_no'); hb=float('$hyp_bm')
print(hb/hn)
PY
)
ratio_dA=$(python3 - <<PY
dn=float('$Dp3A_no'); db=float('$Dp3A_bm')
print(db/dn)
PY
)
ratio_dB=$(python3 - <<PY
dn=float('$Dp3B_no'); db=float('$Dp3B_bm')
print(db/dn)
PY
)

ratio_sqA=$(python3 - <<PY
rh=float('$ratio_h'); rd=float('$ratio_dA')
print(rd/(rh*rh) if rh!=0 else float('nan'))
PY
)
ratio_sqB=$(python3 - <<PY
rh=float('$ratio_h'); rd=float('$ratio_dB')
print(rd/(rh*rh) if rh!=0 else float('nan'))
PY
)

cat <<EOF
# Off-axis 1 Jy source beam-factor test (DP3 predict vs hyperdrive simulate)
# pointing (deg): ra0=$ra0 dec0=$dec0
# source (deg):   ra1=$ra1 dec1=$dec1  (OFF_DEG=$OFF_DEG mode=$OFF_MODE)
# hyperdrive model: $hyp_model_txt
# dp3 model: $DP3_MODEL

mean(|DATA|):
  hyp_nobeam = $hyp_no
  hyp_beam   = $hyp_bm

  dp3(msin=hyp_nobeam) nobeam = $Dp3A_no
  dp3(msin=hyp_nobeam) beam   = $Dp3A_bm

  dp3(msin=birli)      nobeam = $Dp3B_no
  dp3(msin=birli)      beam   = $Dp3B_bm

attenuation ratios:
  R_h  = hyp_beam/hyp_nobeam          = $ratio_h
  R_dA = dp3_beam/dp3_nobeam (msin=h) = $ratio_dA
  R_dB = dp3_beam/dp3_nobeam (msin=b) = $ratio_dB

  R_dA / (R_h^2) = $ratio_sqA
  R_dB / (R_h^2) = $ratio_sqB

Outputs in: $outdir/
EOF
