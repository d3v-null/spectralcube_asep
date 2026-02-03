# Based on https://github.com/d3v-null/hpc-docker-images/blob/main/dp3-mwa.Dockerfile
# Builder uses Spack to install DP3 + EveryBeam, with an MWA beam fix patch.

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

# Add an EveryBeam patch to fix MWA ITRF direction handling.
# DP3 passes ITRF *direction cosines*, but EveryBeam was treating them as meters.
RUN source /opt/spack/share/spack/setup-env.sh && \
    cat > /opt/ska-sdp-spack/packages/everybeam/mwapoint-itrf-direction.patch <<'PATCH'
diff --git a/cpp/pointresponse/mwapoint.cc b/cpp/pointresponse/mwapoint.cc
--- a/cpp/pointresponse/mwapoint.cc
+++ b/cpp/pointresponse/mwapoint.cc
@@ -102,15 +102,18 @@ void MWAPoint::Response(aocommon::MC2x2* result, BeamMode beam_mode,
   const telescope::MWA& mwatelescope =
       static_cast<const telescope::MWA&>(GetTelescope());
   casacore::MeasFrame frame(mwatelescope.GetArrayPosition(), time_epoch);
-  const casacore::Vector<double> itrf_coord(
-      {itrf_direction[0], itrf_direction[1], itrf_direction[2]});
-  const casacore::Quantum<casacore::Vector<double>> itrf(itrf_coord, "m");
-  const casacore::MDirection direction_itrf(itrf, casacore::MDirection::ITRF);
+
+  // itrf_direction is a unit direction cosine vector in ITRF, not meters.
+  const casacore::MDirection direction_itrf(
+      casacore::MVDirection(itrf_direction[0], itrf_direction[1],
+                            itrf_direction[2]),
+      casacore::MDirection::Ref(casacore::MDirection::ITRF, frame));
   casacore::MDirection::Convert measure_converter(
       casacore::MDirection::Ref(casacore::MDirection::ITRF, frame),
       casacore::MDirection::J2000);
   const casacore::Vector<double> j2000_dir =
-      measure_converter(itrf).getValue().getValue();
+      measure_converter(direction_itrf).getValue().getValue();
PATCH

# Sanity checks: patch file must be non-empty, end with newline, and contain no NUL bytes.
RUN source /opt/spack/share/spack/setup-env.sh && \
    test -s /opt/ska-sdp-spack/packages/everybeam/mwapoint-itrf-direction.patch && \
    python3 - <<'PY'
from pathlib import Path
p = Path('/opt/ska-sdp-spack/packages/everybeam/mwapoint-itrf-direction.patch')
b = p.read_bytes()
assert b'\0' not in b, 'patch contains NUL bytes'
assert b.endswith(b'\n'), 'patch missing trailing newline'
print('patch bytes:', len(b))
PY

# Inject the patch into the EveryBeam Spack package at v0.7.4.
RUN source /opt/spack/share/spack/setup-env.sh && \
    python3 -c "import pathlib; p=pathlib.Path('/opt/ska-sdp-spack/packages/everybeam/package.py'); txt=p.read_text(); imp='from spack.package import depends_on, join_path, variant, version, which\\n'; imp2='from spack.package import depends_on, join_path, variant, version, which, patch\\n'; txt = (txt.replace(imp, imp2) if (imp in txt and 'which, patch' not in txt) else txt); ver='    version(\\\"0.7.4\\\", tag=\\\"v0.7.4\\\", submodules=True)\\n'; patchline='    patch(\\\"mwapoint-itrf-direction.patch\\\", when=\\\"@0.7.4\\\")\\n'; txt = (txt.replace(ver, ver+patchline) if (ver in txt and patchline not in txt) else txt); assert ver in txt, 'everybeam package.py missing 0.7.4 version line'; p.write_text(txt)"

# ----------------
# Spack environment setup (layer 1): config + concretize
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
      'everybeam@=0.7.4~python' \
      'dp3@master~python' && \
    spack -e /opt/spack_env concretize --force && \
    # Cap build parallelism for reliability.
    spack -e /opt/spack_env config add "config:build_jobs:4"

# ----------------
# Spack install (layer 2): dependencies only
# ----------------
RUN --mount=type=cache,target=/opt/buildcache \
    source /opt/spack/share/spack/setup-env.sh && \
    spack -e /opt/spack_env install --use-buildcache=auto --reuse \
      --only=dependencies --no-check-signature --fail-fast --test=root

# ----------------
# Spack install (layer 3): roots (dp3 + everybeam + hdf5)
# ----------------
RUN --mount=type=cache,target=/opt/buildcache \
    source /opt/spack/share/spack/setup-env.sh && \
    spack -e /opt/spack_env install --use-buildcache=auto --reuse \
      --no-check-signature --fail-fast --test=root && \
    test -x /opt/view/bin/DP3

FROM ubuntu:jammy AS runtime

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
