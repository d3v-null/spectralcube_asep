# Based on https://github.com/d3v-null/hpc-docker-images/blob/main/dp3-mwa.Dockerfile
# Builder uses Spack to install DP3 + EveryBeam.

FROM spack/ubuntu-jammy:1.0.1 AS builder
SHELL ["/bin/bash", "-lc"]

RUN apt update && apt-get --no-install-recommends install -y \
    wget \
    cmake \
    libcfitsio-dev \
    git \
    curl \
    libcurl4-openssl-dev \
    python3 \
    python3-dev \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Clone ska-sdp-spack and register as an extra repo.
# NOTE: older spack versions had trouble with dash namespaces; keep it safe.
RUN source /opt/spack/share/spack/setup-env.sh && \
    rm -rf /opt/ska-sdp-spack && \
    git clone https://gitlab.com/ska-telescope/sdp/ska-sdp-spack.git /opt/ska-sdp-spack && \
    sed -i 's/namespace: ska-sdp-spack/namespace: ska_sdp_spack/' /opt/ska-sdp-spack/repo.yaml || true && \
    spack repo add /opt/ska-sdp-spack

# ----------------
# Spack environment setup: config + concretize
# ----------------
RUN --mount=type=cache,target=/opt/buildcache \
    source /opt/spack/share/spack/setup-env.sh && \
    # Force a more widely-available target to maximize buildcache hits.
    spack config --scope site add "packages:all:target:[x86_64_v2]" && \
    mkdir -p /opt/{software,spack_env,view} && \
    spack env create --dir /opt/spack_env && \
    spack -e /opt/spack_env config add "config:install_tree:root:/opt/software" && \
    spack -e /opt/spack_env config add "view:/opt/view" && \
    # Mirrors
    spack mirror add --scope site --autopush --unsigned --type binary local-buildcache file:///opt/buildcache && \
    spack mirror add --scope site --type binary spack-public \
      https://binaries.spack.io/release/developer-tools-x86_64_v2-linux-gnu/build_cache && \
    spack mirror add --scope site --type source spack-source https://mirror.spack.io && \
    spack mirror list && \
    spack buildcache keys --install --trust || true && \
    # Prefer apt-provided tools where possible.
    printf '%s\n' \
      'packages:' \
      '  python:' \
      '    buildable: false' \
      '    externals:' \
      '    - spec: python@3.10.12' \
      '      prefix: /usr' \
      '  git:' \
      '    buildable: false' \
      '    externals:' \
      '    - spec: git@2.34.1' \
      '      prefix: /usr' \
      '  curl:' \
      '    buildable: false' \
      '    externals:' \
      '    - spec: curl@7.81.0' \
      '      prefix: /usr' \
      > /tmp/packages-externals.yaml && \
    spack config --scope site add -f /tmp/packages-externals.yaml && \
    # Add + concretize.
    spack -e /opt/spack_env add \
      'hdf5+threadsafe' \
      'everybeam@0.8.0: ~python' \
      'dp3@master~python' && \
    spack -e /opt/spack_env concretize --force && \
    # Cap build parallelism for reliability.
    spack -e /opt/spack_env config add "config:build_jobs:4"

# DO NOT EDIT ABOVE THIS LINE
# ----------------
# Spack install: dependencies only
# ----------------
RUN --mount=type=cache,target=/opt/buildcache \
    source /opt/spack/share/spack/setup-env.sh && \
    spack -e /opt/spack_env install --use-buildcache=auto --reuse \
    --only=dependencies --no-check-signature --fail-fast --test=root

# EveryBeam: use upstream fix from master (commit 2614beaf). No patching needed.
# Add a Spack version entry that pins that commit as 0.8.0.
RUN source /opt/spack/share/spack/setup-env.sh && \
    python3 - <<'PY'
import pathlib
p = pathlib.Path('/opt/ska-sdp-spack/packages/everybeam/package.py')
txt = p.read_text()
ver_line = '    version("0.8.0", commit="2614beaf", submodules=True)\n'
if 'version("0.8.0",' not in txt and ver_line not in txt:
    # Insert near the top of the version list. If a master/develop version exists,
    # insert after it; otherwise insert after the class docstring/variants area.
    lines = txt.splitlines(True)
    # Find first existing version() line.
    idx = next((i for i,l in enumerate(lines) if l.lstrip().startswith('version(')), None)
    if idx is None:
        raise SystemExit('everybeam package.py: no version() lines found')
    lines.insert(idx, ver_line)
    txt = ''.join(lines)
    p.write_text(txt)
print('everybeam: ensured version 0.8.0@2614beaf present')
PY

# ----------------
# Spack install: roots (dp3 + everybeam + hdf5)
# ----------------
RUN --mount=type=cache,target=/opt/buildcache \
    source /opt/spack/share/spack/setup-env.sh && \
    spack -e /opt/spack_env install --use-buildcache=auto --reuse \
      --no-check-signature --fail-fast --test=root && \
    test -x /opt/view/bin/DP3

RUN source /opt/spack/share/spack/setup-env.sh && \
    spack gc -y

# ----------------
# Runtime stage: copy over the installed software and the Spack environment from the builder stage
# ----------------
FROM ubuntu:jammy AS runtime

# Spack is a Python application; install a minimal Python runtime.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    python3 \
    libpython3.10 \
    libcurl4 \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/software /opt/software
COPY --from=builder /opt/view /opt/view
COPY --from=builder /opt/spack_env /opt/spack_env
COPY --from=builder /opt/spack /opt/spack
COPY --from=builder /opt/ska-sdp-spack /opt/ska-sdp-spack

ENV SPACK_ROOT=/opt/spack \
    PATH=/opt/view/bin:/opt/software/bin:/usr/local/bin:/usr/bin:/bin

RUN . /opt/spack/share/spack/setup-env.sh && \
    spack repo add /opt/ska-sdp-spack && \
    spack env activate /opt/spack_env && \
    echo ". /opt/spack/share/spack/setup-env.sh" >> /etc/profile.d/spack.sh && \
    echo "spack env activate /opt/spack_env" >> /etc/profile.d/spack.sh

RUN printf '%s\n' \
    '#!/bin/bash' \
    'source /opt/spack/share/spack/setup-env.sh' \
    'spack env activate /opt/spack_env' \
    'exec "$@"' \
    > /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh

# Smoke test: fail the image build if DP3 cannot start due to missing shared libs.
RUN ldd /opt/view/bin/DP3 | tee /tmp/ldd.txt && ! grep -q "not found" /tmp/ldd.txt
RUN OPENBLAS_NUM_THREADS=1 /opt/view/bin/DP3 --version

# Smoke test data layer: download reference MS + stage MWA beam coefficients in /opt.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    g++ \
    cmake \
    make \
    tar \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-lc"]
RUN set -euo pipefail; \
    cd /opt; \
    curl -L --fail --retry 3 -o hyp_model_1099487728_src500.ms.zip \
      "https://projects.pawsey.org.au/mwa-demo/hyp_model_1099487728_src500.ms.zip"; \
    unzip -q hyp_model_1099487728_src500.ms.zip; \
    rm -f hyp_model_1099487728_src500.ms.zip; \
    test -d /opt/hyp_model_1099487728_src500.ms

# Keep the beam coefficients as a stable reference file.
COPY mwa_full_embedded_element_pattern.h5 /opt/mwa_full_embedded_element_pattern.h5

# Smoke test: force EveryBeam to evaluate an MWA (FEE) beam using the reference MS.
# Uses the pattern from:
#   https://raw.githubusercontent.com/cjordan/mwa_hyperbeam/.../everybeam_example.cpp
SHELL ["/bin/bash", "-lc"]
RUN <<'BASH'
set -euo pipefail

# Tooling already installed in an earlier layer.

tmpdir="$(mktemp -d)"
cd "$tmpdir"

test -d /opt/hyp_model_1099487728_src500.ms
test -s /opt/mwa_full_embedded_element_pattern.h5

cat > eb_mwa_eval.cc <<'CPP'
#include <EveryBeam/beammode.h>
#include <EveryBeam/beamnormalisationmode.h>
#include <EveryBeam/pointresponse/pointresponse.h>
#include <EveryBeam/telescope/mwa.h>
#include <aocommon/coordinatesystem.h>
#include <casacore/ms/MeasurementSets/MeasurementSet.h>
#include <casacore/tables/Tables/ScalarColumn.h>

#include <cmath>
#include <complex>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <memory>

int main() {
  const char* ms_path = "/opt/hyp_model_1099487728_src500.ms";
  const char* beam_path = "/opt/mwa_full_embedded_element_pattern.h5";

  casacore::MeasurementSet ms(ms_path);
  casacore::ScalarColumn<double> time_col(ms, "TIME");
  const double time0 = time_col(0);

  constexpr double DEC_RAD = -27.0 * M_PI / 180.0;
  constexpr double FREQ_HZ = 150e6;

  // Scan ~20 points in RA around 0 deg, 1 deg apart ([-9, +10] deg)
  constexpr int RA_START_DEG = -9;
  constexpr int RA_END_DEG = 10;

  everybeam::Options options;
  options.coeff_path = beam_path;
  options.beam_normalisation_mode = everybeam::BeamNormalisationMode::kFull;
  options.beam_mode = everybeam::BeamMode::kFull;
  options.frequency_interpolation = false;

  everybeam::telescope::MWA beam(ms, options);
  std::unique_ptr<everybeam::pointresponse::PointResponse> pr = beam.GetPointResponse(time0);

  bool any_ok = false;
  for(int ra_deg = RA_START_DEG; ra_deg <= RA_END_DEG; ++ra_deg) {
    const double ra_rad = double(ra_deg) * M_PI / 180.0;

    std::complex<float> jones[4];
    pr->Response(everybeam::BeamMode::kFull, jones, ra_rad, DEC_RAD, FREQ_HZ, 0, 0);

    const double amp = std::abs(jones[0]) + std::abs(jones[1]) + std::abs(jones[2]) + std::abs(jones[3]);

    std::cout << std::setprecision(8)
              << "RA_deg=" << ra_deg
              << " DEC_deg=" << (-27.0)
              << " J00=" << jones[0] << " J01=" << jones[1]
              << " J10=" << jones[2] << " J11=" << jones[3]
              << " |sumabs|=" << amp << "\n";

    any_ok = any_ok || (amp > 1.0e-6);
  }

  if (!any_ok) {
    std::cerr << "EveryBeam MWA response is near-zero for all scan points (unexpected)\n";
    return 1;
  }
  return 0;
}
CPP

cat > CMakeLists.txt <<'CMAKE'
cmake_minimum_required(VERSION 3.16)
project(eb_mwa_eval CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_PREFIX_PATH "/opt/view/lib/everybeam")

set(AOCOMMON_INCLUDE_DIR "" CACHE PATH "Path to directory containing aocommon headers")

find_package(EveryBeam CONFIG REQUIRED)
add_executable(eb_mwa_eval eb_mwa_eval.cc)

target_include_directories(eb_mwa_eval PRIVATE /opt/view/include ${EVERYBEAM_INCLUDE_DIRS})
if(AOCOMMON_INCLUDE_DIR)
  target_include_directories(eb_mwa_eval PRIVATE "${AOCOMMON_INCLUDE_DIR}")
endif()

target_link_directories(eb_mwa_eval PRIVATE /opt/view/lib)
# Some exported EveryBeam targets refer to -lhdf5_cpp-shared; ensure the linker can resolve it.
target_link_libraries(eb_mwa_eval PRIVATE EveryBeam::everybeam)
CMAKE

# Fetch aocommon headers from GitLab at a known commit.
AOCOMMON_SHA=7120f1999ec20057a2d3035f12619fc099735ed4
curl -L --fail --retry 3 -o aocommon.tgz \
  "https://gitlab.com/aroffringa/aocommon/-/archive/${AOCOMMON_SHA}/aocommon-${AOCOMMON_SHA}.tar.gz"
tar -xzf aocommon.tgz
AOCOMMON_SRC_DIR="$(find . -maxdepth 1 -type d -name 'aocommon-*' | head -n 1)"
test -n "$AOCOMMON_SRC_DIR"
test -d "$AOCOMMON_SRC_DIR/include/aocommon"
AOCOMMON_INCLUDE_DIR="$tmpdir/aocommon/include"
mkdir -p "$AOCOMMON_INCLUDE_DIR"
cp -a "$AOCOMMON_SRC_DIR/include/aocommon" "$AOCOMMON_INCLUDE_DIR/"

# Work around exported target referring to -lhdf5_cpp-shared
ln -sf /opt/view/lib/libhdf5_cpp.so /opt/view/lib/libhdf5_cpp-shared.so

cmake -S . -B build -DAOCOMMON_INCLUDE_DIR="$AOCOMMON_INCLUDE_DIR"
cmake --build build -j
./build/eb_mwa_eval > /opt/eb_mwa_eval.txt

cd /
rm -rf "$tmpdir"
BASH
