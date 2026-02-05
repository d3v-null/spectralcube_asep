# DP3 source build (local dev)

This host is Ubuntu 20.04; building DP3 + deps natively is painful. The practical dev setup is:

- Use the existing dependency stack from the `d3vnull0/dp3-mwa:latest` container (`/opt/view`).
- Mount this repo and build DP3 from source into `dp3_build_host/`.

## One-time
```bash
cd /home/ubuntu/spectralcube_asep
# Get DP3 source
git clone https://github.com/lofar-astron/DP3.git DP3_src
```

## Build (inside container)
```bash
cd /home/ubuntu/spectralcube_asep
mkdir -p dp3_build_host

# Build
docker run --rm -it -e OPENBLAS_NUM_THREADS=1 \
  -v "$PWD:$PWD" -w "$PWD" \
  d3vnull0/dp3-mwa:latest bash -lc '
    git config --global --add safe.directory /home/ubuntu/spectralcube_asep/DP3_src
    # (submodules also need to be marked safe)
    for d in /home/ubuntu/spectralcube_asep/DP3_src/external/*; do git config --global --add safe.directory "$d"; done

    cd /home/ubuntu/spectralcube_asep/dp3_build_host
    cmake ../DP3_src -DCMAKE_PREFIX_PATH=/opt/view -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build . -j 4

    ./DP3 --version
  '
```

## Edit/rebuild loop
- Edit code in `DP3_src/` (host-side).
- Re-run the container build command above.

## Run your rebuilt DP3
The rebuilt binary is:
- `dp3_build_host/DP3`

To run it on data:
```bash
docker run --rm -e OPENBLAS_NUM_THREADS=1 \
  -v "$PWD:$PWD" -w "$PWD" \
  d3vnull0/dp3-mwa:latest bash -lc '
    cd /home/ubuntu/spectralcube_asep/dp3_build_host
    ./DP3 msin=... steps=[predict] ...
  '
```
