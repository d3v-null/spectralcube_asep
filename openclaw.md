Your task is to perform a repeatable comparison of visibility subtraction methods:
- [gleamx uvsub](https://github.com/GLEAM-X/GLEAM-X-pipeline/blob/dug_processing/templates/uvsub.tmpl)
- [hyperdrive peel](https://github.com/MWATelescope/mwa-demo/blob/main/WORKSHOP_04.md)
- [DP3 DDEcal](DP3_notes.md)

You should use the [birli_1271676902-t0002_vv_8s_10kHz.ms](1271676902.md) dataset for this comparison.

```bash
wget https://projects.pawsey.org.au/mwa-demo/birli_1271676902-t0002_vv_8s_10kHz.ms.zip -O birli_1271676902-t0002_vv_8s_10kHz.ms.zip
unzip birli_1271676902-t0002_vv_8s_10kHz.ms.zip
```

An MWA beam model is available here:

```bash
MWA_BEAM_FILE=mwa_full_embedded_element_pattern.h5
curl -L -o $MWA_BEAM_FILE "http://ws.mwatelescope.org/static/beams/${MWA_BEAM_FILE##*/}"
```

A sky model is available here:

```bash
srclist=GGSM_updated.fits
curl -L -o $srclist "https://github.com/GLEAM-X/GLEAM-X-pipeline/raw/master/models/${srclist##*/}"
```

First step is to DI Calibrate the data.

## DI Cal - DP3

```bash
# DP3 DI cal (gaincal) using a DP3/LoFAR-format sky model.
# This follows the working pattern in DP3_notes.md, adapted to this dataset.

# Inputs
ms=birli_1271676902-t0002_vv_8s_10kHz.ms
metafits=1271676902.metafits
beam=mwa_full_embedded_element_pattern.h5
srclist_fits=GGSM_updated.fits

# 1) Build a compact AO sky model (top N by beam-weighted flux)
#    (DP3 can't ingest the FITS srclist directly; we convert below.)
hyperdrive srclist-by-beam \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --metafits ${metafits} \
  --number 250 \
  --beam-file ${beam} \
  -o ao \
  ${srclist_fits} \
  1271676902_reduced_n250.txt

# 2) Convert AO source list -> DP3 sourcedb/skymodel text (via lofartools)
model_in=1271676902_reduced_n250.txt
model_out=${model_in%.txt}.skymodel.txt
docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
  editmodel -skymodel ${model_out} ${model_in}

# 3) Run DP3 gaincal (full-Jones) and write calibrated visibilities to a new MS
# NOTE: the dp3-mwa image is referenced in DP3_notes.md
export OPENBLAS_NUM_THREADS=1
docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=${ms} \
  msout=dp3_1271676902_di.ms \
  steps=[gaincal] \
  gaincal.sourcedb=${model_out} \
  gaincal.parmdb=gc_solutions_1271676902.h5 \
  gaincal.caltype=fulljones \
  gaincal.usebeammodel=true \
  gaincal.uvlambdamin=30 \
  gaincal.maxiter=300 \
  gaincal.tolerance=1e-20 \
  gaincal.applysolution=true \
  gaincal.coefficients_path=${beam} \
  gaincal.solint=3 \
  gaincal.nchan=1 \
  msout.overwrite=true

# Optional QA
# losoto gc_solutions_1271676902.h5 /path/to/losoto.parset
```

## DI Cal - hyperdrive

```bash
# hyperdrive DI cal (di-calibrate), producing solutions + an optionally calibrated MS

# Inputs
ms=birli_1271676902-t0002_vv_8s_10kHz.ms
metafits=1271676902.metafits
beam=mwa_full_embedded_element_pattern.h5
srclist_fits=GGSM_updated.fits

# 1) Build a compact AO sky model (top N by beam-weighted flux)
hyperdrive srclist-by-beam \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --metafits ${metafits} \
  --number 250 \
  --beam-file ${beam} \
  -o ao \
  ${srclist_fits} \
  1271676902_reduced_n250.txt

# 2) Solve DI gains (full-Jones) against this model
/usr/bin/time -v hyperdrive di-calibrate \
  --uvw-min 75l --uvw-max 1667l \
  --max-iterations 300 --stop-thresh 1e-20 \
  --source-dist-cutoff=180 --veto-threshold 0.005 \
  --data ${metafits} ${ms} \
  --beam-file ${beam} \
  --source-list 1271676902_reduced_n250.txt \
  --outputs hyp_soln_1271676902_75-1667l_src250_300it.fits

# Optional: plot solutions
# hyperdrive solutions-plot hyp_soln_1271676902_75-1667l_src250_300it.fits

# Optional: apply solutions and write a calibrated MS
hyperdrive solutions-apply \
  --solutions hyp_soln_1271676902_75-1667l_src250_300it.fits \
  --data ${metafits} ${ms} \
  --outputs hyp_1271676902_di.ms
```