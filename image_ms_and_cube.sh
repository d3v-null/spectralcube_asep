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
prefix=${2:-img}

IM_SIZE=${IM_SIZE:-2048}
FOV_DEG=${FOV_DEG:-120}
NCH=${NCH:-24}
POL=${POL:-xx,yy}
DATA_COLUMN=${DATA_COLUMN:-DATA}
WSCLEAN_ARGS=${WSCLEAN_ARGS:-}
CHGCENTRE_MINW=${CHGCENTRE_MINW:-0}
GPSTIME=${GPSTIME:-1099487728}

if [[ ! -e "$ms" ]]; then
  echo "ERROR: MS not found: $ms" >&2
  exit 2
fi

if ! command -v wsclean >/dev/null; then
  echo "ERROR: wsclean not in PATH" >&2
  exit 2
fi
if ! command -v python3 >/dev/null; then
  echo "ERROR: python3 not in PATH" >&2
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

wsclean -name "$base" \
  -size "$IM_SIZE" "$IM_SIZE" -scale "$scale" \
  -channels-out "$NCH" -join-channels \
  -pol "$POL" \
  -niter 0 \
  -weight natural \
  -data-column "$DATA_COLUMN" \
  $WSCLEAN_ARGS \
  "$work_ms"

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
