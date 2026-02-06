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
    git checkout 2026.02.1 && \
    sed -i 's/namespace: ska-sdp-spack/namespace: ska_sdp_spack/' /opt/ska-sdp-spack/repo.yaml || true && \
    spack repo add /opt/ska-sdp-spack

# EveryBeam: use upstream fix from master (commit 2614beaf).
RUN source /opt/spack/share/spack/setup-env.sh && \
    python3 - <<'PY'
import pathlib
p = pathlib.Path('/opt/ska-sdp-spack/packages/everybeam/package.py')
txt = p.read_text()
# Add git commit sha to the package recipe so we can install it by commit hash.
ver_line = '    version("0.8.0.20251125", commit="2614beafba64f5f5d326b783c486c765a3729889", submodules=True)\n'
if ver_line not in txt:
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
PY

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
      'everybeam@=0.8.0.20251125 ~python' \
      'dp3@6.5.1.20260109 ~python' && \
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

  // Scan ~80 points in RA around 0 deg, 1 deg apart ([-39, +40] deg)
  constexpr int RA_START_DEG = -39;
  constexpr int RA_END_DEG = 40;

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
cat /opt/eb_mwa_eval.txt
cd /
rm -rf "$tmpdir"
BASH

# docker build -f dp3.Dockerfile -t d3vnull0/dp3-mwa:latest . --progress=plain && docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest cat /opt/eb_mwa_eval.txt
# RA_deg=-39 DEC_deg=-27 J00=(0.13676697,0.037693392) J01=(0.030163191,0.0077810404) J10=(0.02764911,0.0047607329) J11=(-0.18996416,-0.033811759) |sumabs|=0.39402252
# RA_deg=-38 DEC_deg=-27 J00=(0.13391545,0.039195489) J01=(0.028533291,0.0077548949) J10=(0.026401794,0.004640121) J11=(-0.18432216,-0.033297114) |sumabs|=0.38321394
# RA_deg=-37 DEC_deg=-27 J00=(0.12948133,0.040324688) J01=(0.026655201,0.0076619755) J10=(0.024906809,0.0044574165) J11=(-0.17681964,-0.032403052) |sumabs|=0.36841646
# RA_deg=-36 DEC_deg=-27 J00=(0.1233412,0.041029975) J01=(0.024533723,0.0074991421) J10=(0.023165535,0.0042115287) J11=(-0.16736345,-0.031096425) |sumabs|=0.3494139
# RA_deg=-35 DEC_deg=-27 J00=(0.11537864,0.041261833) J01=(0.022176504,0.0072638649) J10=(0.021182334,0.0039022618) J11=(-0.15587145,-0.029345445) |sumabs|=0.32601917
# RA_deg=-34 DEC_deg=-27 J00=(0.10548609,0.040972877) J01=(0.019594127,0.0069543435) J10=(0.018964604,0.0035303074) J11=(-0.14227396,-0.027120205) |sumabs|=0.29808176
# RA_deg=-33 DEC_deg=-27 J00=(0.093566902,0.0401184) J01=(0.016800182,0.0065696342) J10=(0.016522823,0.003097218) J11=(-0.12651514,-0.02439324) |sumabs|=0.26549989
# RA_deg=-32 DEC_deg=-27 J00=(0.079537354,0.038656969) J01=(0.013811259,0.0061097709) J10=(0.013870534,0.0026053726) J11=(-0.10855424,-0.021140087) |sumabs|=0.22824281
# RA_deg=-31 DEC_deg=-27 J00=(0.063328713,0.03655095) J01=(0.010646885,0.0055758767) J10=(0.011024288,0.0020579323) J11=(-0.088366926,-0.017339876) |sumabs|=0.18640518
# RA_deg=-30 DEC_deg=-27 J00=(0.044889174,0.0337671) J01=(0.0073293904,0.0049702493) J10=(0.0080035375,0.0014587925) J11=(-0.065946393,-0.012975888) |sumabs|=0.14037362
# RA_deg=-29 DEC_deg=-27 J00=(0.024185719,0.030277124) J01=(0.0038836959,0.0042964229) J10=(0.0048304838,0.00081253599) J11=(-0.041304417,-0.0080361087) |sumabs|=0.091519997
# RA_deg=-28 DEC_deg=-27 J00=(0.0012058227,0.026058318) J01=(0.00033703423,0.0035591887) J10=(0.0015298616,0.00012438513) J11=(-0.014472243,-0.0025137402) |sumabs|=0.045885153
# RA_deg=-27 DEC_deg=-27 J00=(-0.024041055,0.021094201) J01=(-0.0032814019,0.0027645754) J10=(-0.0018713223,-0.00059984386) J11=(0.014498645,0.0035923359) |sumabs|=0.053176306
# RA_deg=-26 DEC_deg=-27 J00=(-0.05152224,0.015375189) J01=(-0.0069408724,0.0019197881) J10=(-0.0053441138,-0.0013537881) J11=(0.045535997,0.010277165) |sumabs|=0.11316317
# RA_deg=-25 DEC_deg=-27 J00=(-0.0811809,0.0088992631) J01=(-0.010609556,0.0010330988) J10=(-0.0088579878,-0.0021305881) J11=(0.078546472,0.017529398) |sumabs|=0.18191631
# RA_deg=-24 DEC_deg=-27 J00=(-0.11293545,0.001672619) J01=(-0.014255061,0.00011369829) J10=(-0.012381281,-0.0029229461) J11=(0.11341559,0.025331063) |sumabs|=0.25613496
# RA_deg=-23 DEC_deg=-27 J00=(-0.14667931,-0.006289748) J01=(-0.017844968,-0.00082849007) J10=(-0.015881671,-0.0037231953) J11=(0.15000798,0.033657432) |sumabs|=0.33472806
# RA_deg=-22 DEC_deg=-27 J00=(-0.18228103,-0.014963542) J01=(-0.021347398,-0.0017830274) J10=(-0.019326707,-0.0045233876) J11=(0.18816787,0.042476982) |sumabs|=0.41706759
# RA_deg=-21 DEC_deg=-27 J00=(-0.21958481,-0.024314802) J01=(-0.024731599,-0.0027391992) J10=(-0.022684392,-0.0053154011) J11=(0.22771996,0.051751487) |sumabs|=0.502635
# RA_deg=-20 DEC_deg=-27 J00=(-0.25841129,-0.034299687) J01=(-0.027968535,-0.0036862702) J10=(-0.025923781,-0.0060910727) J11=(0.26847056,0.061436173) |sumabs|=0.5909282
# RA_deg=-19 DEC_deg=-27 J00=(-0.29855886,-0.044864465) J01=(-0.031031488,-0.0046137497) J10=(-0.029015655,-0.006842359) J11=(0.31020889,0.071480013) |sumabs|=0.68143284
# RA_deg=-18 DEC_deg=-27 J00=(-0.33980504,-0.055945694) J01=(-0.03389667,-0.0055116564) J10=(-0.031933192,-0.0075615253) J11=(0.35270888,0.081826121) |sumabs|=0.77361381
# RA_deg=-17 DEC_deg=-27 J00=(-0.38190827,-0.06747064) J01=(-0.036543846,-0.006370787) J10=(-0.034652717,-0.0082413657) J11=(0.39573082,0.092412189) |sumabs|=0.86691439
# RA_deg=-16 DEC_deg=-27 J00=(-0.42460996,-0.079357885) J01=(-0.038957004,-0.0071829814) J10=(-0.037154485,-0.0088754501) J11=(0.43902349,0.10317107) |sumabs|=0.96075892
# RA_deg=-15 DEC_deg=-27 J00=(-0.46763662,-0.091518164) J01=(-0.041125074,-0.0079413923) J10=(-0.039423522,-0.0094584087) J11=(0.48232609,0.11403136) |sumabs|=1.0545572
# RA_deg=-14 DEC_deg=-27 J00=(-0.51070219,-0.1038554) J01=(-0.043042742,-0.008640768) J10=(-0.04145062,-0.0099862432) J11=(0.52537054,0.12491816) |sumabs|=1.1477106
# RA_deg=-13 DEC_deg=-27 J00=(-0.55351067,-0.11626784) J01=(-0.044711445,-0.0092777647) J10=(-0.043233421,-0.010456687) J11=(0.56788361,0.13575375) |sumabs|=1.2396184
# RA_deg=-12 DEC_deg=-27 J00=(-0.5957585,-0.12864938) J01=(-0.046140596,-0.0098513085) J10=(-0.044777799,-0.010869613) J11=(0.60958898,0.1464584) |sumabs|=1.3296854
# RA_deg=-11 DEC_deg=-27 J00=(-0.63713741,-0.14089097) J01=(-0.047349226,-0.010363053) J10=(-0.046099614,-0.011227542) J11=(0.65020961,0.15695117) |sumabs|=1.4173306
# RA_deg=-10 DEC_deg=-27 J00=(-0.67733717,-0.15288199) J01=(-0.048368283,-0.010817985) J10=(-0.047227062,-0.011536281) J11=(0.6894697,0.16715075) |sumabs|=1.5019972
# RA_deg=-9 DEC_deg=-27 J00=(-0.71604824,-0.16451177) J01=(-0.049243938,-0.011225297) J10=(-0.048204094,-0.011805802) J11=(0.72709703,0.17697631) |sumabs|=1.5831647
# RA_deg=-8 DEC_deg=-27 J00=(-0.75296491,-0.17567094) J01=(-0.05004264,-0.011599672) J10=(-0.049095485,-0.012051528) J11=(0.76282459,0.18634824) |sumabs|=1.6603644
# RA_deg=-7 DEC_deg=-27 J00=(-0.78778762,-0.18625276) J01=(-0.050859164,-0.01196332) J10=(-0.049994893,-0.012296331) J11=(0.79639286,0.19518903) |sumabs|=1.7332013
# RA_deg=-6 DEC_deg=-27 J00=(-0.8202256,-0.19615428) J01=(-0.051829942,-0.012349338) J10=(-0.051038217,-0.012573836) J11=(0.82755095,0.20342377) |sumabs|=1.8013859
# RA_deg=-5 DEC_deg=-27 J00=(-0.84999835,-0.20527726) J01=(-0.053156499,-0.012807572) J10=(-0.052426964,-0.012934211) J11=(0.8560577,0.21098073) |sumabs|=1.8647845
# RA_deg=-4 DEC_deg=-27 J00=(-0.87683547,-0.21352839) J01=(-0.055149056,-0.01341552) J10=(-0.054471865,-0.013454966) J11=(0.88168031,0.2177912) |sumabs|=1.9235079
# RA_deg=-3 DEC_deg=-27 J00=(-0.90047204,-0.22081849) J01=(-0.058314145,-0.014300207) J10=(-0.057680424,-0.014262704) J11=(0.90418911,0.22378835) |sumabs|=1.9780831
# RA_deg=-2 DEC_deg=-27 J00=(-0.92063153,-0.22705838) J01=(-0.063548155,-0.015686499) J10=(-0.06295047,-0.015581228) J11=(0.92333996,0.22890294) |sumabs|=2.0298142
# RA_deg=-1 DEC_deg=-27 J00=(-0.9369688,-0.2321448) J01=(-0.072623447,-0.018018452) J10=(-0.072056323,-0.017852461) J11=(0.93881667,0.23304917) |sumabs|=2.0816691
# RA_deg=0 DEC_deg=-27 J00=(-0.94885147,-0.23590575) J01=(-0.089652985,-0.022324985) J10=(-0.089113779,-0.022100942) J11=(0.95001245,0.23607042) |sumabs|=2.1408458
# RA_deg=1 DEC_deg=-27 J00=(-0.95418823,-0.23780759) J01=(-0.12696183,-0.031685833) J10=(-0.1264533,-0.031395145) J11=(0.95486081,0.23744868) |sumabs|=2.2284656
# RA_deg=2 DEC_deg=-27 J00=(-0.93665081,-0.2337622) J01=(-0.24535732,-0.061286159) J10=(-0.24490468,-0.060871311) J11=(0.93707466,0.23313205) |sumabs|=2.4362717
# RA_deg=3 DEC_deg=-27 J00=(0.22428499,0.056058157) J01=(-0.94371188,-0.23563042) J10=(-0.94401169,-0.23488455) J11=(-0.22385049,-0.055634033) |sumabs|=2.4073231
# RA_deg=4 DEC_deg=-27 J00=(0.94236404,0.23518793) J01=(-0.22042377,-0.054949511) J10=(-0.22092541,-0.055022944) J11=(-0.94257522,-0.23446327) |sumabs|=2.3974116
# RA_deg=5 DEC_deg=-27 J00=(0.95412946,0.23775244) J01=(-0.12039006,-0.02993443) J10=(-0.12084997,-0.030119846) J11=(-0.95472437,-0.23738323) |sumabs|=2.2157013
# RA_deg=6 DEC_deg=-27 J00=(0.94777244,0.23556535) J01=(-0.08673919,-0.021490976) J10=(-0.087155797,-0.021730544) J11=(-0.948915,-0.23576277) |sumabs|=2.1335588
# RA_deg=7 DEC_deg=-27 J00=(0.93531442,0.23163345) J01=(-0.071005441,-0.017514013) J10=(-0.071371794,-0.017795511) J11=(-0.93718171,-0.2326028) |sumabs|=2.0758762
# RA_deg=8 DEC_deg=-27 J00=(0.91850984,0.22640534) J01=(-0.062528156,-0.015339127) J10=(-0.062834404,-0.015661273) J11=(-0.92126548,-0.22834191) |sumabs|=2.0242827
# RA_deg=9 DEC_deg=-27 J00=(0.89793158,0.22003803) J01=(-0.057614356,-0.014042141) J10=(-0.057848766,-0.014408144) J11=(-0.90171695,-0.2231234) |sumabs|=1.9723277
# RA_deg=10 DEC_deg=-27 J00=(0.87391043,0.21263137) J01=(-0.054637026,-0.013215166) J10=(-0.054786563,-0.013630609) J11=(-0.87883925,-0.21703021) |sumabs|=1.917316
# RA_deg=11 DEC_deg=-27 J00=(0.84671968,0.20427398) J01=(-0.052760847,-0.012648458) J10=(-0.05281166,-0.013120312) J11=(-0.8528738,-0.21013115) |sumabs|=1.8580635
# RA_deg=12 DEC_deg=-27 J00=(0.81662416,0.19505528) J01=(-0.051508635,-0.012222178) J10=(-0.051446535,-0.012758219) J11=(-0.82405043,-0.20249327) |sumabs|=1.7941048
# RA_deg=13 DEC_deg=-27 J00=(0.78389531,0.18506907) J01=(-0.050585728,-0.011862558) J10=(-0.050396681,-0.012470972) J11=(-0.7926029,-0.19418569) |sumabs|=1.7253641
# RA_deg=14 DEC_deg=-27 J00=(0.74881476,0.17441414) J01=(-0.049799521,-0.011521807) J10=(-0.049470186,-0.012210929) J11=(-0.75877368,-0.18528058) |sumabs|=1.6519963
# RA_deg=15 DEC_deg=-27 J00=(0.71167439,0.16319393) J01=(-0.049019024,-0.011168007) J10=(-0.048537306,-0.01194614) J11=(-0.72281486,-0.17585319) |sumabs|=1.5743057
# RA_deg=16 DEC_deg=-27 J00=(0.67277461,0.15151551) J01=(-0.048152979,-0.010779632) J10=(-0.047508616,-0.011654936) J11=(-0.68498701,-0.16598135) |sumabs|=1.492697
# RA_deg=17 DEC_deg=-27 J00=(0.63242173,0.13948846) J01=(-0.047137305,-0.010342396) J10=(-0.04632242,-0.011322819) J11=(-0.64555776,-0.15574485) |sumabs|=1.4076461
# RA_deg=18 DEC_deg=-27 J00=(0.59092551,0.12722355) J01=(-0.045927517,-0.0098473281) J10=(-0.044937156,-0.010940566) J11=(-0.60480005,-0.14522463) |sumabs|=1.3196783
# RA_deg=19 DEC_deg=-27 J00=(0.54859614,0.11483129) J01=(-0.044493914,-0.0092895534) J10=(-0.043326549,-0.010502997) J11=(-0.56298989,-0.13450199) |sumabs|=1.2293539
# RA_deg=20 DEC_deg=-27 J00=(0.50574154,0.10242049) J01=(-0.04281842,-0.0086674616) J10=(-0.04147635,-0.01000813) J11=(-0.5204044,-0.12365778) |sumabs|=1.1372561
# RA_deg=21 DEC_deg=-27 J00=(0.46266443,0.090096831) J01=(-0.040892377,-0.007982133) J10=(-0.039382044,-0.0094565526) J11=(-0.47731954,-0.1127715) |sumabs|=1.0439813
# RA_deg=22 DEC_deg=-27 J00=(0.41966,0.077961512) J01=(-0.038714986,-0.0072368914) J10=(-0.037047178,-0.0088509312) J11=(-0.43400818,-0.1019206) |sumabs|=0.95013034
# RA_deg=23 DEC_deg=-27 J00=(0.37701294,0.066109896) J01=(-0.036292087,-0.0064369603) J10=(-0.034481995,-0.0081956014) J11=(-0.39073768,-0.091179579) |sumabs|=0.85630155
# RA_deg=24 DEC_deg=-27 J00=(0.33499515,0.054630425) J01=(-0.033635218,-0.0055891545) J10=(-0.031702355,-0.0074962149) J11=(-0.34776771,-0.080619372) |sumabs|=0.76308346
# RA_deg=25 DEC_deg=-27 J00=(0.29386348,0.043603569) J01=(-0.030760793,-0.0047016032) J10=(-0.028728778,-0.0067594247) J11=(-0.30534837,-0.070306577) |sumabs|=0.67105001
# RA_deg=26 DEC_deg=-27 J00=(0.25385728,0.033101056) J01=(-0.027689399,-0.0037834849) J10=(-0.025585582,-0.0059926086) J11=(-0.2637178,-0.060302872) |sumabs|=0.58075547
# RA_deg=27 DEC_deg=-27 J00=(0.21519685,0.023185235) J01=(-0.024445143,-0.0028447602) J10=(-0.02230012,-0.0052036233) J11=(-0.22310038,-0.050664485) |sumabs|=0.49273238
# RA_deg=28 DEC_deg=-27 J00=(0.17808126,0.013908726) J01=(-0.021055009,-0.0018959069) J10=(-0.018902034,-0.0044005872) J11=(-0.18370497,-0.041441709) |sumabs|=0.40749264
# RA_deg=29 DEC_deg=-27 J00=(0.14268722,0.005314244) J01=(-0.017548265,-0.00094765081) J10=(-0.015422567,-0.0035916953) J11=(-0.14572316,-0.032678556) |sumabs|=0.32553756
# RA_deg=30 DEC_deg=-27 J00=(0.10916778,-0.0025653637) J01=(-0.013955857,-1.0702643e-05) J10=(-0.011893917,-0.0027850631) J11=(-0.10932799,-0.024412468) |sumabs|=0.24738985
# RA_deg=31 DEC_deg=-27 J00=(0.077651531,-0.0097068837) J01=(-0.010309807,0.00090449961) J10=(-0.008348627,-0.0019886002) J11=(-0.074672885,-0.016674168) |sumabs|=0.17369938
# RA_deg=32 DEC_deg=-27 J00=(0.048242155,-0.016096354) J01=(-0.0066426387,0.001788031) J10=(-0.004819016,-0.0012099053) J11=(-0.041890759,-0.0094875908) |sumabs|=0.10565601
# RA_deg=33 DEC_deg=-27 J00=(0.02101835,-0.021728547) J01=(-0.0029868067,0.0026306964) J10=(-0.0013366546,-0.00045618444) J11=(-0.011093611,-0.0028699224) |sumabs|=0.047082119
# RA_deg=34 DEC_deg=-27 J00=(-0.0039658975,-0.026606388) J01=(0.00062584894,0.0034242177) J10=(0.0020681066,0.00026581393) J11=(0.01762772,0.0031682462) |sumabs|=0.050376572
# RA_deg=35 DEC_deg=-27 J00=(-0.026680674,-0.030740282) J01=(0.0041646096,0.0041613802) J10=(0.0053665601,0.00094985467) J11=(0.044203453,0.0086226827) |sumabs|=0.09707804
# RA_deg=36 DEC_deg=-27 J00=(-0.047119159,-0.03414746) J01=(0.007600341,0.0048361411) J10=(0.0085320091,0.0015902631) J11=(0.068584532,0.013495181) |sumabs|=0.14577872
# RA_deg=37 DEC_deg=-27 J00=(-0.065296359,-0.036851306) J01=(0.010905906,0.0054436903) J10=(0.011540079,0.0021819698) J11=(0.090742052,0.017793164) |sumabs|=0.19138122
# RA_deg=38 DEC_deg=-27 J00=(-0.081247598,-0.038880713) J01=(0.014056505,0.005980466) J10=(0.014368976,0.0027205553) J11=(0.1106665,0.021529205) |sumabs|=0.23271284
# RA_deg=39 DEC_deg=-27 J00=(-0.095026776,-0.040269464) J01=(0.01702996,0.0064441352) J10=(0.016999684,0.0032022968) J11=(0.1283668,0.024720524) |sumabs|=0.2694397
# RA_deg=40 DEC_deg=-27 J00=(-0.10670451,-0.041055668) J01=(0.019806914,0.0068335277) J10=(0.01941612,0.0036242139) J11=(0.1438693,0.027388424) |sumabs|=0.30148745