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
      'everybeam@0.8.0: ~python' \
      'dp3@master~python' && \
    spack -e /opt/spack_env concretize --force && \
    # Cap build parallelism for reliability.
    spack -e /opt/spack_env config add "config:build_jobs:4"

# DO NOT EDIT ABOVE THIS LINE
# ----------------
# Spack install (layer 2): dependencies only
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
