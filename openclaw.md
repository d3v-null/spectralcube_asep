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

these are different.

```txt
# docker run --rm -v $PWD:$PWD --entrypoint $PWD/taql_compare.sh d3vnull0/dp3-mwa:latest $PWD/*_model_1099487728_src500.ms
-- DATA stats
using style glish select countall() as nrows, gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from /home/ubuntu/spectralcube_asep/dp3_model_1099487728_src500.ms
    has been executed
    select result of 1 rows
3 selected columns:  nrows sum_abs mean_abs
8128    3.04483e+06     3.90219

-- DATA stats
using style glish select countall() as nrows, gsum(sum(abs(DATA))) as sum_abs, gmean(mean(abs(DATA))) as mean_abs from /home/ubuntu/spectralcube_asep/hyp_model_1099487728_src500.ms
    has been executed
    select result of 1 rows
3 selected columns:  nrows sum_abs mean_abs
8128    1.632e+07       20.9153
```

First step is to DI Calibrate the data.

## DI Cal - DP3

```bash
# DP3 DI cal (gaincal) using a DP3/LoFAR-format sky model.
# This follows the working pattern in DP3_notes.md, adapted to this dataset.

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
