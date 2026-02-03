#!/usr/bin/env bash
set -euo pipefail

# Build + run the EveryBeam MWA grid lookup inside the dp3-mwa container.
# Writes real(J_xx) to a txt file for a 5x5 grid with 1 degree spacing.

ms=${1:-hyp_model_1099487728_src500.ms}
beam=${2:-mwa_full_embedded_element_pattern.h5}
out=${3:-beam_xx_real_grid.txt}

export RA0_DEG=${RA0_DEG:-0}
export DEC0_DEG=${DEC0_DEG:--27}
export STEP_DEG=${STEP_DEG:-1}
export NGRID=${NGRID:-5}
export FREQ_HZ=${FREQ_HZ:-150e6}

img=${DP3_MWA_IMAGE:-d3vnull0/dp3-mwa:latest}

MS_PATH="$PWD/$ms"
BEAM_PATH="$PWD/$beam"
OUT_PATH="$PWD/$out"

# Pass all runtime parameters via env so we can keep the container script single-quoted.
docker run --rm \
  -e MS_PATH="$MS_PATH" \
  -e BEAM_PATH="$BEAM_PATH" \
  -e OUT_PATH="$OUT_PATH" \
  -e RA0_DEG -e DEC0_DEG -e STEP_DEG -e NGRID -e FREQ_HZ \
  -v "$PWD:$PWD" -w "$PWD" \
  "$img" bash -lc '
    set -euo pipefail
    tmp="$(mktemp -d)"
    cp -a beam_lookup_grid.cc "$tmp/"
    cp -a CMakeLists.txt.beam_lookup_grid "$tmp/CMakeLists.txt"

    # Work around some builds exporting -lhdf5_cpp-shared
    if [[ -e /opt/view/lib/libhdf5_cpp.so ]]; then
      ln -sf /opt/view/lib/libhdf5_cpp.so /opt/view/lib/libhdf5_cpp-shared.so || true
    fi

    # Fetch aocommon headers (EveryBeam depends on them)
    AOCOMMON_SHA=7120f1999ec20057a2d3035f12619fc099735ed4
    curl -L --fail --retry 3 -o "$tmp/aocommon.tgz" \
      "https://gitlab.com/aroffringa/aocommon/-/archive/${AOCOMMON_SHA}/aocommon-${AOCOMMON_SHA}.tar.gz"
    tar -xzf "$tmp/aocommon.tgz" -C "$tmp"
    AOCOMMON_SRC_DIR=$(find "$tmp" -maxdepth 1 -type d -name "aocommon-*" | head -n 1)
    mkdir -p "$tmp/aocommon_include"
    cp -a "$AOCOMMON_SRC_DIR/include/aocommon" "$tmp/aocommon_include/"

    cmake -S "$tmp" -B "$tmp/build" -DAOCOMMON_INCLUDE_DIR="$tmp/aocommon_include"
    cmake --build "$tmp/build" -j

    "$tmp/build/beam_lookup_grid" \
      --ms "$MS_PATH" \
      --beam "$BEAM_PATH" \
      --ra0-deg "$RA0_DEG" --dec0-deg "$DEC0_DEG" --step-deg "$STEP_DEG" --n "$NGRID" --freq-hz "$FREQ_HZ" \
      --out "$OUT_PATH"

    rm -rf "$tmp"
  '

echo "Wrote $out"
