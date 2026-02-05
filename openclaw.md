Your task is to perform a repeatable comparison of visibility subtraction methods:
- [gleamx uvsub](https://github.com/GLEAM-X/GLEAM-X-pipeline/blob/dug_processing/templates/uvsub.tmpl)
- [hyperdrive peel](https://github.com/MWATelescope/mwa-demo/blob/main/WORKSHOP_04.md)
- [DP3 DDEcal](DP3_notes.md)

You should use the dataset defined below for this comparison.

```bash
export obsid=1099487728;
# preprocessing settings:
export freqres_khz=40
export timeres_s=4
# calibration settings:
export dical_args="--timesteps $(echo {4..5})"
export apply_args="${dical_args}"
export dical_suffix="_t4-5"
# - calibrate (and later subtract) 500 sources
export num_sources=500

# File naming conventions (guessed based on settings)
ms=birli_${obsid}_${timeres_s}s_${freqres_khz}kHz.ms
metafits=${obsid}.metafits
MWA_BEAM_FILE=mwa_full_embedded_element_pattern.h5
srclist=GGSM_updated.fits
model_in=${obsid}_reduced_n${num_sources}.txt
model_out=${model_in%.txt}.skymodel.txt
```

```bash
# Note: The URL is constructed based on previous patterns but may need adjustment for this specific obsid/resolution
# birli --no-sel-flagged-ants --avg-time-res 4 --avg-freq-res 40 --van-vleck -M birli_1099487728_4s_40kHz.ms -m 1099487728.metafits -- 1099487728_2*gpubox*.fits
wget https://projects.pawsey.org.au/mwa-demo/${ms}.zip -O ${ms}.zip
unzip ${ms}.zip
# metafits
wget http://ws.mwatelescope.org/metadata/fits?obs_id=${obsid} -O ${metafits}
```

An MWA beam model is available here:

```bash
curl -L -o $MWA_BEAM_FILE "http://ws.mwatelescope.org/static/beams/${MWA_BEAM_FILE##*/}"
```

A sky model is available here:

```bash
curl -L -o $srclist "https://github.com/GLEAM-X/GLEAM-X-pipeline/raw/master/models/${srclist##*/}"
```

Zeroth step is to ensure that both calibration methods produce a similar model

## Sky Model - hyperdrive vs DP3

```bash
# Inputs are defined at the top

# 1) Build a compact AO sky model (top N by beam-weighted flux)
#    (DP3 can't ingest the FITS srclist directly; we convert below.)
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive srclist-by-beam \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --metafits ${metafits} \
  --number ${num_sources} \
  --beam-file ${MWA_BEAM_FILE} \
  -o ao \
  ${srclist_fits} \
  ${obsid}_reduced_n${num_sources}.txt

# 2) Convert AO source list -> DP3 sourcedb/skymodel text (via lofartools)
docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
  editmodel -skymodel ${model_out} ${model_in}

```

first: without beam

```bash
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --freq-res 1280 --num-fine-channels 24 \
  --time-res 8 --num-timesteps 1 \
  --metafits ${metafits} \
  --no-beam \
  --source-list ${obsid}_reduced_n${num_sources}.txt \
  --output-model-files hyp_model_${obsid}_src${num_sources}_no_beam.ms

export OPENBLAS_NUM_THREADS=1
docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=hyp_model_${obsid}_src${num_sources}_no_beam.ms \
  msout=dp3_model_${obsid}_src${num_sources}_no_beam.ms \
  steps=[predict] \
  predict.sourcedb=${model_out} \
  predict.usebeammodel=false \
  msout.overwrite=true
```

they're the same.

```txt
# docker run --rm -v $PWD:$PWD --entrypoint $PWD/taql_compare.sh d3vnull0/dp3-mwa:latest $PWD/*_model_${obsid}_src${num_sources}_no_beam.ms
==== Comparing column DATA ====
-- DATA stats
using style glish select countall() as nrows, gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from /home/ubuntu/spectralcube_asep/dp3_model_1099487728_src500_no_beam.ms
    has been executed
    select result of 1 rows
3 selected columns:  nrows sum_abs mean_abs
8128    8.81865e+07     113.018

-- DATA stats
using style glish select countall() as nrows, gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from /home/ubuntu/spectralcube_asep/hyp_model_1099487728_src500_no_beam.ms
    has been executed
    select result of 1 rows
3 selected columns:  nrows sum_abs mean_abs
8128    8.81855e+07     113.017
```

with beam

```bash
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --freq-res 1280 --num-fine-channels 24 \
  --time-res 8 --num-timesteps 1 \
  --metafits ${metafits} \
  --beam-file ${MWA_BEAM_FILE} \
  --source-list ${obsid}_reduced_n${num_sources}.txt \
  --output-model-files hyp_model_${obsid}_src${num_sources}.ms

docker run --rm -v "$PWD:$PWD" -w $PWD mwatelescope/cotter fixmwams hyp_model_${obsid}_src${num_sources}.ms ${metafits}

export OPENBLAS_NUM_THREADS=1
docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=hyp_model_${obsid}_src${num_sources}.ms \
  msout=dp3_model_${obsid}_src${num_sources}.ms \
  steps=[predict] \
  predict.sourcedb=${model_out} \
  predict.usebeammodel=true \
  predict.coefficients_path=${MWA_BEAM_FILE} \
  msout.overwrite=true
```

these are now the same.

```txt
# docker run --rm -v $PWD:$PWD --entrypoint $PWD/taql_compare.sh d3vnull0/dp3-mwa:latest $PWD/{hyp,dp3}_model_1099487728_src500.ms
-- DATA stats
using style glish select countall() as nrows, gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from /home/ubuntu/spectralcube_asep/hyp_model_1099487728_src500.ms
    has been executed
    select result of 1 rows
3 selected columns:  nrows sum_abs mean_abs
8128    1.632e+07       20.9153

-- DATA stats
using style glish select countall() as nrows, gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from /home/ubuntu/spectralcube_asep/dp3_model_1099487728_src500.ms
    has been executed
    select result of 1 rows
3 selected columns:  nrows sum_abs mean_abs
8128    1.65897e+07     21.2609
```

also confirm with images

```bash
cd /home/ubuntu/spectralcube_asep
for ms in {hyp,dp3}_model_${obsid}_src${num_sources}.ms; do
  docker run --rm --user 0:0 -e OPENBLAS_NUM_THREADS=1 \
  -v "$PWD:$PWD" -w "$PWD" \
  images.canfar.net/srcnet/sp5505:sha-ceb56ad-cpu \
  wsclean -name ebdiag/${ms%.ms} \
  -j 16 \
  -temp-dir /tmp \
  -size 1024 1024 -scale 0.117188 \
  -pol xx,yy -niter 0 -weight natural \
  -data-column DATA \
  -apply-primary-beam -pb-grid-size 1024 \
  -mwa-path "$PWD" \
  $ms
done
```


First step is to DI Calibrate the data.

---

# DP3: Direction-dependent subtraction options (DDECal vs Demix)

This section extends the comparison plan with DP3's two main approaches for removing a small number of extremely bright sources:

- **DDECal** (general direction-dependent calibration; can solve multiple directions jointly; supports frequency-dependent behaviour via `nchan` and/or `smoothnessconstraint`).
- **Demix** (specialised "A-team" style demixing; solves a bright direction and subtracts it; typically assumes gains are constant over the solved bandwidth, so it is best done in relatively narrow frequency chunks).

The goal here is a *repeatable* DP3-side comparison that is consistent with the dataset and file conventions at the top of this document.

## When to use which

### DDECal (recommended default for "top N" bright directions)
Use DDECal when:
- you have **several** bright sources contaminating the field (e.g. 5 directions),
- you want to solve **all directions together** (joint fit),
- you need behaviour that is **stable across bandwidth** (via `nchan` blocks and/or `smoothnessconstraint`).

### Demix (useful for a single monster source)
Use demix when:
- you have **one** exceptionally bright off-axis source dominating a sidelobe (Sun / Cas A / etc.),
- you want a quick "remove that one thing" step,
- you are willing to assume gains are (approximately) **constant in frequency** over the demix band.

A pragmatic hybrid is: **demix the single most extreme source first**, then run **DDECal** on the remaining directions.

## Common DP3 settings that matter (MWA)

These are the knobs that most strongly affect correctness/stability/runtime:

- **Beam model**: for MWA use `*.usebeammodel=true` and set `*.coefficients_path=${MWA_BEAM_FILE}`.
- **Baseline cut**: short baselines include diffuse emission not in a point-source model; keep `uvlambdamin` (or equivalent selection) consistent with your DI cal (here: `30λ`).
- **Solution interval**:
  - time: `solint` is in number of input timesteps.
  - freq: `nchan` is number of input channels per solution.
- **Smoothness constraint**: `smoothnessconstraint` regularises frequency variation (Gaussian smoothing kernel width in Hz).

For this dataset (4s × 40 kHz), a reasonable starting point for bright-source peeling is:
- `solint ~ 15` (≈60s)
- `nchan ~ 8` (≈320 kHz)
- `smoothnessconstraint ~ 1e6–2e6` (≈1–2 MHz)
- solve **diagonal** gains unless you have a strong reason to fit full Jones.

## Step 0: Build a "bright 5" sky model for DP3

You need a DP3 skymodel that contains only the few bright sources you want to peel, **clustered into patches/directions**.

A repeatable way to do this is:
1) Reduce to AO format (hyperdrive) for the full catalogue.
2) Select the brightest few sources (or brightest few *patches*) and assign them patch names.
3) Convert AO -> DP3 skymodel text.

### Fully automated patch/direction generation (recommended)

To make the comparison reproducible, generate DP3 directions (patches) automatically using lofartools.
This clusters the input AO sky model into `cluster1..clusterK`, then converts to a DP3 skymodel.

From this repo (already includes the helper script):

```bash
# Build 5 clusters from the existing 500-source AO model
# Input:  1099487728_reduced_n500.txt
# Output: bright5.ao.txt + bright5.skymodel.txt

./build_bright_clusters.sh 1099487728_reduced_n500.txt 5 bright5.ao.txt bright5.skymodel.txt

# Directions will be: cluster1,cluster2,cluster3,cluster4,cluster5
bright5_ao=bright5.ao.txt
bright5_dp3=bright5.skymodel.txt
```

This removes the need to hand-name patches like `POINTING`.

---

## A) DDECal comparison run

### 1) Run DDECal and subtract

Example parset-style invocation (command-line keys):

```bash
export OPENBLAS_NUM_THREADS=1

# Solve DDE gains in 5 directions and subtract their model
# (adjust directions list to match your skymodel patch names)

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=${ms} \
  msout=dp3_${obsid}_ddecal_sub.ms \
  steps=[ddecal] \
  ddecal.sourcedb=${bright5_dp3} \
  ddecal.directions=[cluster1,cluster2,cluster3,cluster4,cluster5] \
  ddecal.mode=diagonal \
  ddecal.solint=15 \
  ddecal.nchan=8 \
  ddecal.usebeammodel=true \
  ddecal.coefficients_path=${MWA_BEAM_FILE} \
  ddecal.uvlambdamin=30 \
  ddecal.smoothnessconstraint=2e6 \
  ddecal.beamproximitylimit=60 \
  ddecal.h5parm=ddecal_solutions_${obsid}.h5 \
  ddecal.subtract=true \
  msout.overwrite=true
```

Notes:
- `ddecal.mode=diagonal` is usually enough for Stokes I peeling; use `fulljones` only if you have evidence you need it.
- `beamproximitylimit` clusters sources close together so the beam is computed once per cluster.

### 2) QA

- Plot the solutions:
  ```bash
  docker run --rm -v "$PWD:$PWD" -w "$PWD" revoltek/pill:20251114 losoto -V ddecal_solutions_${obsid}.h5 losoto-fullj.parset
  ```
- Image before/after to assess residuals around the peeled sources (WSClean dirty imaging is fine; ensure consistent parameters).
- Compare vis stats before/after subtract (e.g. TAQL mean(|DATA|), flagged fraction).

---

## B) Demix comparison run

Demix is most appropriate for removing *one* extremely bright off-axis source. For 5 sources, you can demix sequentially, but that is usually less attractive than a single DDECal solve unless one source is a clear outlier.

### 1) Demix a single bright source

DP3 demix configuration is SourceDB/patch-driven. Conceptually:
- `subtractsources` = the source/patch to remove
- optionally: `modelsources` = other sources to include in the solve model (but not subtract)
- optionally: `targetsource` = a direction you want to preserve (solve but do not subtract)

Example (pseudo-parset; names depend on your skymodel):

```bash
export OPENBLAS_NUM_THREADS=1

# Demix one bright source (example: patch1)

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=${ms} \
  msout=dp3_${obsid}_demix_patch1.ms \
  steps=[demix] \
  demix.sourcedb=${bright5_dp3} \
  demix.subtractsources=[cluster1] \
  demix.usebeammodel=true \
  demix.coefficients_path=${MWA_BEAM_FILE} \
  demix.solint=15 \
  demix.nchan=8 \
  demix.uvlambdamin=30 \
  demix.h5parm=demix_patch1_${obsid}.h5 \
  msout.overwrite=true
```

**Important:** Demix often assumes gains are constant over the solved bandwidth. If you demix across a very wide band, you can leave spectral residuals. If needed, run demix per sub-band/chunk.

### 2) Sequential demix for multiple sources (optional)

If you insist on demixing multiple sources, do it iteratively:
- output of previous demix becomes `msin` of the next.
- keep the same baseline cuts and beam settings.

---

## DDECal vs Demix: what to compare fairly

To compare DDECal vs Demix in a way that is meaningful:

1) **Same input MS** (same flags, same averaging)
2) **Same sky model content** (same 5 sources/patches; same flux scale)
3) **Same baseline cuts** (`uvlambdamin`, etc.)
4) **Same beam model** (`usebeammodel`, `coefficients_path`)
5) **Comparable solution intervals** (`solint`, `nchan`)

Metrics to record:
- Runtime + peak memory
- Residual image dynamic range around the peeled sources
- Change in visibility statistics (mean(|DATA|), etc.)
- Stability/structure of solutions (do they look smooth in time/frequency?)

---

## Practical recommendation for this project

For "remove 5 brightest sources" on this MWA dataset, start with **DDECal** in diagonal mode with moderate `solint` and either small `nchan` blocks or a `smoothnessconstraint`.

Consider Demix only if:
- one source is overwhelmingly dominant and far off-axis, and
- you want to remove it first to avoid contaminating a joint DDECal solve.

(See `dp3_demix.md` for the parameter rationale and pitfalls.)

## DI Cal - DP3

```bash
# DP3 DI cal (gaincal) using a DP3/LoFAR-format sky model.
# This follows the working pattern in DP3_notes.md, adapted to this dataset.

# MWA MS fix
docker run --rm -v "$PWD:$PWD" -w $PWD mwatelescope/cotter fixmwams ${ms} ${metafits}
# docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-convert \
#   --data ${metafits} ${ms} \
#   --outputs hyp_${ms}.ms
# docker run --rm -v "$PWD:$PWD" -w $PWD mwatelescope/cotter fixmwams hyp_${ms}.ms ${metafits}


[ -f gc_solutions_${obsid}.h5 ] && rm -rf gc_solutions_${obsid}.h5
[ -d dp3_${obsid}_di.ms ] && rm -rf dp3_${obsid}_di.ms
# 3) Run DP3 gaincal (full-Jones) and write calibrated visibilities to a new MS
# NOTE: solint and nchan are the number of time and frequency channels to average over
# 27 * 4s = 108s = 1.8 minutes
export OPENBLAS_NUM_THREADS=1
docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=${ms} \
  msout=dp3_${obsid}_di.ms \
  steps=[gaincal] \
  gaincal.sourcedb=${model_out} \
  gaincal.parmdb=gc_solutions_${obsid}.h5 \
  gaincal.caltype=fulljones \
  gaincal.usebeammodel=true \
  gaincal.uvlambdamin=30 \
  gaincal.maxiter=300 \
  gaincal.tolerance=1e-20 \
  gaincal.applysolution=true \
  gaincal.coefficients_path=${MWA_BEAM_FILE} \
  gaincal.solint=27 \
  gaincal.nchan=32 \
  msout.overwrite=true

# Percentage of flagged visibilities detected per correlation:
#   [0,0,0,0] out of 168542208 visibilities   [0%, 0%, 0%, 0%]
# 0 missing time slots were inserted

# Total DP3 time    4007.12 real     10341.8 user      531.33 system
#     0.2% ( 6804 ms) MsReader
#    99.3% ( 3981  s) GainCal gaincal.
#            92.0% ( 3662  s) of it spent in predict
#             0.2% ( 9010 ms) of it spent in reordering visibility data
#             7.6% (  300  s) of it spent in estimating gains and computing residuals
#             0.0% (    3 ms) of it spent in writing gain solutions to disk
#         Converged: 0, stalled: 24, non converged: 0, failed: 0
#         Iters converged: 0, stalled: 63, non converged: 0, failed: 0
#     0.0% ( 1832 ms) MSWriter msout.
#       0.0% (    0 ms) Creating task
#     421.3% ( 7717 ms) Writing (threaded)

# Optional QA: plot the gaincal solutions with LiLF/losoto
docker run --rm -v "$PWD:$PWD" -w "$PWD" revoltek/pill:20251114 losoto -V gc_solutions_${obsid}.h5 losoto-fullj.parset
```

## DI Cal - hyperdrive

```bash
# hyperdrive DI cal (di-calibrate), producing solutions + an optionally calibrated MS

# Inputs are defined at the top

# 1) Build a compact AO sky model (top N by beam-weighted flux)
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive srclist-by-beam \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --metafits ${metafits} \
  --number ${num_sources} \
  --beam-file ${MWA_BEAM_FILE} \
  -o ao \
  ${srclist_fits} \
  ${obsid}_reduced_n${num_sources}.txt

# 2) Solve DI gains (full-Jones) against this model
# Uses ${dical_args} which contains --timesteps
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive di-calibrate \
  --uvw-min 75l --uvw-max 1667l \
  --max-iterations 300 --stop-thresh 1e-20 \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --freq-average 1280kHz \
  ${dical_args} \
  --data ${metafits} ${ms} \
  --beam-file ${MWA_BEAM_FILE} \
  --source-list ${obsid}_reduced_n${num_sources}.txt \
  --outputs hyp_soln_${obsid}_75-1667l_1280kHz_src${num_sources}_300it.fits

# Optional: plot solutions
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive solutions-plot  --max-amp 2.0 hyp_soln_${obsid}_75-1667l_1280kHz_src${num_sources}_300it.fits

# Optional: apply solutions and write a calibrated MS
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive solutions-apply \
  --solutions hyp_soln_${obsid}_75-1667l_1280kHz_src${num_sources}_300it.fits \
  --data ${metafits} ${ms} \
  --outputs hyp_${obsid}_di.ms
```

Imaging

```bash
docker run --rm -v $PWD:$PWD --entrypoint $PWD/image_ms_and_cube.sh d3vnull0/dp3-mwa:latest $PWD/birli_1099487728_4s_40kHz.ms
```

```bash
# cd /home/ubuntu/spectralcube_asep
# docker run --rm --user 0:0 -e OPENBLAS_NUM_THREADS=1 \
# -v "$PWD:$PWD" -w "$PWD" \
# images.canfar.net/srcnet/sp5505:sha-ceb56ad-cpu \
# wsclean -name ebdiag_birli \
# -j 4 \
# -temp-dir /tmp \
# -size 1024 1024 -scale 0.117188 \
# -channels-out 24 -join-channels \
# -pol xx,yy -niter 0 -weight natural \
# -data-column DATA \
# -apply-primary-beam -pb-grid-size 32 \
# -mwa-path "$PWD" \
# birli_1099487728_4s_40kHz.ms


cd /home/ubuntu/spectralcube_asep
docker run --rm --user 0:0 -e OPENBLAS_NUM_THREADS=1 \
-v "$PWD:$PWD" -w "$PWD" \
images.canfar.net/srcnet/sp5505:sha-ceb56ad-cpu \
wsclean -name ebdiag_birli \
-j 16 \
-temp-dir /tmp \
-size 1024 1024 -scale 0.117188 \
-pol xx,yy -niter 0 -weight natural \
-data-column DATA \
-apply-primary-beam -pb-grid-size 1024 \
-mwa-path "$PWD" \
hyp_${ms}.ms
```

carta

```bash
docker run --rm -it \
  -v "$PWD:/images" \
  -w "/images" \
  -p 3005:3005 \
  cartavis/carta:latest \
  --port 3005
```