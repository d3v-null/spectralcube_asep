#!/usr/bin/env bash
set -euo pipefail

# Build + run the EveryBeam sampler that reads WSClean SIN WCS from a beam FITS
# and evaluates the EveryBeam Jones response at sample pixels.
#
# Usage:
#   ./run_eb_wsclean_wcs_sample.sh <ms> <beam_h5> <wsclean_beam0_fits> [out_txt]

ms=${1:?"ms required"}
beam=${2:?"beam h5 required"}
wbeam=${3:?"wsclean beam FITS required"}
out=${4:-eb_wsclean_wcs_samples.txt}

FREQ_HZ=${FREQ_HZ:-139515000}
GRID=${GRID:-5}
STEP_PIX=${STEP_PIX:-64}

img=${DP3_MWA_IMAGE:-d3vnull0/dp3-mwa:latest}

# We build inside dp3-mwa (EveryBeam+casacore). Need aocommon headers.
docker run --rm \
  -e OPENBLAS_NUM_THREADS=1 \
  -v "$PWD:$PWD" -w "$PWD" \
  "$img" bash -lc "
    set -euo pipefail
    tmp=\"\$(mktemp -d)\"
    cp -a eb_wsclean_wcs_sample.cc \"\$tmp/\"
    cp -a CMakeLists.txt.eb_wcs \"\$tmp/CMakeLists.txt\"

    # aocommon headers (same SHA as dp3.Dockerfile used)
    AOCOMMON_SHA=7120f1999ec20057a2d3035f12619fc099735ed4
    curl -L --fail --retry 3 -o \"\$tmp/aocommon.tgz\" \
      \"https://gitlab.com/aroffringa/aocommon/-/archive/\${AOCOMMON_SHA}/aocommon-\${AOCOMMON_SHA}.tar.gz\"
    tar -xzf \"\$tmp/aocommon.tgz\" -C \"\$tmp\"
    AOCOMMON_SRC_DIR=\$(find \"\$tmp\" -maxdepth 1 -type d -name 'aocommon-*' | head -n 1)
    mkdir -p \"\$tmp/aocommon_include\"
    cp -a \"\$AOCOMMON_SRC_DIR/include/aocommon\" \"\$tmp/aocommon_include/\"

    # Work around exported target referring to -lhdf5_cpp-shared
    if [[ -e /opt/view/lib/libhdf5_cpp.so ]]; then
      ln -sf /opt/view/lib/libhdf5_cpp.so /opt/view/lib/libhdf5_cpp-shared.so || true
    fi

    cmake -S \"\$tmp\" -B \"\$tmp/build\" -DAOCOMMON_INCLUDE_DIR=\"\$tmp/aocommon_include\"
    cmake --build \"\$tmp/build\" -j

    \"\$tmp/build/eb_wsclean_wcs_sample\" \
      --ms \"$PWD/$ms\" \
      --beam \"$PWD/$beam\" \
      --wsclean-beam-fits \"$PWD/$wbeam\" \
      --freq-hz \"$FREQ_HZ\" \
      --grid \"$GRID\" \
      --step-pix \"$STEP_PIX\" \
      --out \"$PWD/$out\"

    rm -rf \"\$tmp\"
  "

echo "Wrote $out"
