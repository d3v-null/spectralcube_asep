#!/usr/bin/env bash
set -euo pipefail

# Image an MS with wsclean (dirty, multi-channel) and pack outputs into a FITS cube
# with a CASAMBM beam table using create_cube_with_beam.py.
#
# Usage:
#   ./image_ms_and_cube.sh <ms> [base_prefix]
#
# Environment overrides:
#   IM_SIZE=2048
#   FOV_DEG=120
#   NCH=24
#   POL=xx,yy        # wsclean pol string
#   DATA_COLUMN=DATA
#   WSCLEAN_ARGS="..."  # extra args appended to wsclean call
#   CHGCENTRE_MINW=1     # run chgcentre -minw on a temp copy (off by default)
#   GPSTIME=1099487728   # passed to create_cube_with_beam.py
#
# Output:
#   <base>-????-XX-image.fits etc
#   <base>-XX-image-cube.fits (and YY)

ms=${1:?"MS path required"}
prefix=${2:-img/}

IM_SIZE=${IM_SIZE:-2048}
FOV_DEG=${FOV_DEG:-120}
NCH=${NCH:-24}
POL=${POL:-xx,yy}
DATA_COLUMN=${DATA_COLUMN:-DATA}
WSCLEAN_ARGS=${WSCLEAN_ARGS:-}
CHGCENTRE_MINW=${CHGCENTRE_MINW:-0}
GPSTIME=${GPSTIME:-1099487728}

# EveryBeam diagnostics (WSClean integration)
APPLY_PRIMARY_BEAM=${APPLY_PRIMARY_BEAM:-0}   # set to 1 to enable -apply-primary-beam
MWA_PATH=${MWA_PATH:-}                        # path containing mwa_full_embedded_element_pattern.h5 (passed via -mwa-path)
PB_GRID_SIZE=${PB_GRID_SIZE:-32}              # passed via -pb-grid-size when APPLY_PRIMARY_BEAM=1

if [[ ! -e "$ms" ]]; then
  echo "ERROR: MS not found: $ms" >&2
  exit 2
fi

WSCLEAN_CONTAINER=${WSCLEAN_CONTAINER:-images.canfar.net/srcnet/sp5505:sha-ceb56ad-cpu}

have_wsclean=0
if command -v wsclean >/dev/null; then
  have_wsclean=1
fi

# We'll run wsclean either natively or inside the container.
# create_cube_with_beam.py is run natively (python3 required).
if ! command -v python3 >/dev/null; then
  echo "ERROR: python3 not in PATH (needed for create_cube_with_beam.py and scale computation)" >&2
  exit 2
fi

# Compute scale (deg/pixel)
scale=$(python3 - <<PY
imsize=int("$IM_SIZE")
fov=float("$FOV_DEG")
print(f"{fov/imsize:.6f}")
PY
)

ms_base=$(basename "$ms")
ms_stem=${ms_base%.ms}
base="${prefix}_${ms_stem}_${IM_SIZE}px_${NCH}ch"

work_ms="$ms"

# Optional: chgcentre -minw requires casacore tools and mutates MS.
# We support it by copying the MS into a temp dir.
if [[ "$CHGCENTRE_MINW" == "1" ]]; then
  if ! command -v chgcentre >/dev/null; then
    echo "ERROR: CHGCENTRE_MINW=1 but chgcentre not in PATH" >&2
    exit 2
  fi
  tmpdir=$(mktemp -d)
  echo "Copying MS to temp for chgcentre: $tmpdir" >&2
  cp -a "$ms" "$tmpdir/${ms_base}"
  work_ms="$tmpdir/${ms_base}"
  echo "Running chgcentre -minw on $work_ms" >&2
  chgcentre -minw "$work_ms" >/dev/null
fi

echo "Imaging $work_ms"
echo "  base=$base"
echo "  imsize=$IM_SIZE scale=$scale deg/pix nch=$NCH pol=$POL datacol=$DATA_COLUMN"
if [[ "$APPLY_PRIMARY_BEAM" == "1" ]]; then
  echo "  EveryBeam: -apply-primary-beam enabled (PB_GRID_SIZE=$PB_GRID_SIZE, MWA_PATH=${MWA_PATH:-<unset>})"
fi

# Assemble EveryBeam args (if enabled)
PB_ARGS=""
if [[ "$APPLY_PRIMARY_BEAM" == "1" ]]; then
  PB_ARGS="-apply-primary-beam -pb-grid-size $PB_GRID_SIZE"
  if [[ -n "${MWA_PATH}" ]]; then
    PB_ARGS="$PB_ARGS -mwa-path $MWA_PATH"
  fi
fi

if [[ "$have_wsclean" == "1" ]]; then
  WSCLEAN_TEMP_DIR=${WSCLEAN_TEMP_DIR:-/tmp}
  WSCLEAN_THREADS=${WSCLEAN_THREADS:-}

  TD_ARGS=""
  if [[ -n "${WSCLEAN_TEMP_DIR}" ]]; then
    TD_ARGS="-temp-dir ${WSCLEAN_TEMP_DIR}"
  fi
  J_ARGS=""
  if [[ -n "${WSCLEAN_THREADS}" ]]; then
    J_ARGS="-j ${WSCLEAN_THREADS}"
  fi

  OPENBLAS_NUM_THREADS=1 wsclean -name "$base" \
    $J_ARGS \
    $TD_ARGS \
    -size "$IM_SIZE" "$IM_SIZE" -scale "$scale" \
    -channels-out "$NCH" -join-channels \
    -pol "$POL" \
    -niter 0 \
    -weight natural \
    -data-column "$DATA_COLUMN" \
    $PB_ARGS \
    $WSCLEAN_ARGS \
    "$work_ms"
else
  echo "wsclean not found; falling back to container: $WSCLEAN_CONTAINER" >&2
  # WSClean writes a temp "*-parted-meta.tmp" next to the MS. Some MS directories are not writable
  # inside the container (permissions/ownership). Work around by copying the MS to a writable temp.
  tmpw=$(mktemp -d)
  echo "Container mode: copying MS to temp writable dir: $tmpw" >&2
  cp -a "$work_ms" "$tmpw/$(basename "$work_ms")"
  work_ms2="$tmpw/$(basename "$work_ms")"

  # Ensure container user can traverse the temp directory
  chmod 755 "$tmpw"
  chmod -R a+rX "$work_ms2"

  docker run --rm \
    --user 0:0 \
    -e OPENBLAS_NUM_THREADS=1 \
    -e PB_ARGS="$PB_ARGS" \
    -v "$tmpw:$tmpw" -w "$tmpw" \
    "$WSCLEAN_CONTAINER" bash -lc "
      set -euo pipefail
      # Force temp dir inside writable mount to avoid parted-meta.tmp permission issues
      wsclean -name '$base' \
        -j ${WSCLEAN_THREADS:-4} \
        -temp-dir '$tmpw' \
        -size '$IM_SIZE' '$IM_SIZE' -scale '$scale' \
        -channels-out '$NCH' -join-channels \
        -pol '$POL' \
        -niter 0 \
        -weight natural \
        -data-column '$DATA_COLUMN' \
        $PB_ARGS \
        $WSCLEAN_ARGS \
        '$work_ms2'
    "

  # Bring results back
  cp -a "$tmpw/${base}-"* .
  rm -rf "$tmpw"
fi

# Determine which suffixes exist (XX-image / YY-image etc.)
# create_cube_with_beam.py expects suff like "XX-image".
for poltag in XX YY; do
  suff="${poltag}-image"
  if ls "${base}-0000-${suff}.fits" >/dev/null 2>&1 || ls "${base}-MFS-${suff}.fits" >/dev/null 2>&1; then
    echo "Creating cube for $suff"
    python3 create_cube_with_beam.py "$base" "$suff" "$NCH" "$GPSTIME"
  else
    echo "Skipping cube for $suff (no FITS found)"
  fi
done

if [[ "$CHGCENTRE_MINW" == "1" ]]; then
  rm -rf "$tmpdir"
fi

echo "Done. Base outputs: ${base}-*"
