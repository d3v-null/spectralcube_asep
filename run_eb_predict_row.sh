#!/usr/bin/env bash
set -euo pipefail

# Build and run eb_predict_row inside dp3-mwa container.
# Usage:
#   ./run_eb_predict_row.sh --ms <ms> --beam <h5> --src-ra-deg <deg> --src-dec-deg <deg> [--flux-jy 1] [--row 0] [--chan 0] [--obs-ms <ms2>]

img=${DP3_MWA_IMAGE:-d3vnull0/dp3-mwa:latest}

docker run --rm \
  -e OPENBLAS_NUM_THREADS=1 \
  -v "$PWD:$PWD" -w "$PWD" \
  "$img" bash -lc "
    set -euo pipefail
    tmp=\"\$(mktemp -d)\"
    cp -a eb_predict_row.cc \"\$tmp/\"
    cp -a CMakeLists.txt.eb_predict_row \"\$tmp/CMakeLists.txt\"

    # aocommon headers
    AOCOMMON_SHA=7120f1999ec20057a2d3035f12619fc099735ed4
    curl -L --fail --retry 3 -o \"\$tmp/aocommon.tgz\" \
      \"https://gitlab.com/aroffringa/aocommon/-/archive/\${AOCOMMON_SHA}/aocommon-\${AOCOMMON_SHA}.tar.gz\"
    tar -xzf \"\$tmp/aocommon.tgz\" -C \"\$tmp\"
    AOCOMMON_SRC_DIR=\$(find \"\$tmp\" -maxdepth 1 -type d -name 'aocommon-*' | head -n 1)
    mkdir -p \"\$tmp/aocommon_include\"
    cp -a \"\$AOCOMMON_SRC_DIR/include/aocommon\" \"\$tmp/aocommon_include/\"

    if [[ -e /opt/view/lib/libhdf5_cpp.so ]]; then
      ln -sf /opt/view/lib/libhdf5_cpp.so /opt/view/lib/libhdf5_cpp-shared.so || true
    fi

    cmake -S \"\$tmp\" -B \"\$tmp/build\" -DAOCOMMON_INCLUDE_DIR=\"\$tmp/aocommon_include\"
    cmake --build \"\$tmp/build\" -j

    \"\$tmp/build/eb_predict_row\" $*

    rm -rf \"\$tmp\"
  "
