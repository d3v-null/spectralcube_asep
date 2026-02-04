# DP3 `predict.usebeammodel=true` on MWA: model visibilities attenuated by ~1e4 vs EveryBeam forward model / hyperdrive

## Summary
When predicting visibilities for an MWA MeasurementSet using DP3 `steps=[predict]` with `predict.usebeammodel=true`, the resulting model visibilities are **orders of magnitude smaller** than both:

- hyperdrive `vis-simulate` with the same source and beam file, and
- a direct forward-model computed from **EveryBeam** Jones matrices + MS UVW phase term.

This suggests a bug in DP3's MWA beam application logic / EveryBeam interface in the `predict` step (e.g. extra/differential/inverse beam term, or incorrect normalisation).

DP3 without beam (`predict.usebeammodel=false`) matches hyperdrive to high precision.

## Environment
- DP3 container: `d3vnull0/dp3-mwa:latest`
- DP3 version: `6.5.1 (v6.5.1-56-g31df6f87)`
- EveryBeam in DP3 container: (from build; WSClean container uses EveryBeam 0.7.4, DP3 container EveryBeam 0.8.0)
- Hyperdrive container: `mwatelescope/mwa-demo:main`
- Beam coefficients: `mwa_full_embedded_element_pattern.h5`

## Data
Observation / MS:
- `birli_1099487728_4s_40kHz.ms`
- `1099487728.metafits`

A minimal 1-source off-axis sky model is used.

## Reproduction (minimal)
All commands below are run in the same directory containing:
- `birli_1099487728_4s_40kHz.ms`
- `1099487728.metafits`
- `mwa_full_embedded_element_pattern.h5`

### 1) Create a single off-axis 1 Jy AO sky model (hyperdrive format)
This places the source ~10 deg off axis in RA at the obs pointing declination.

```bash
# (RA/Dec used here are produced by dp3_vs_hyp_1src_beam_factor.sh from metafits)
cat > 1src_offaxis.ao.txt <<'EOF'
skymodel fileformat 1.1
source {
  name "OFFAX_1JY"
  component {
    type point
    position 0h57m28.2089s -26d47m10.1193s
    sed {
      frequency 200 MHz
      fluxdensity Jy 1.0 0 0 0
      spectral-index { 0.0 0.00 }
    }
  }
}
EOF
```

Convert AO -> DP3 skymodel text (via lofartools):

```bash
docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
  editmodel -skymodel 1src_offaxis.skymodel.txt 1src_offaxis.ao.txt
```

### 2) Hyperdrive simulate visibilities (beam on/off)
```bash
docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
  --source-dist-cutoff=180 --veto-threshold 0 \
  --freq-res 1280 --num-fine-channels 24 \
  --time-res 8 --num-timesteps 1 \
  --metafits 1099487728.metafits \
  --no-beam \
  --source-list 1src_offaxis.ao.txt \
  --output-model-files hyp_1src_nobeam.ms

docker run --rm --entrypoint /entrypoint.sh -v "$PWD:$PWD" -w "$PWD" mwatelescope/mwa-demo:main hyperdrive vis-simulate \
  --source-dist-cutoff=180 --veto-threshold 0 \
  --freq-res 1280 --num-fine-channels 24 \
  --time-res 8 --num-timesteps 1 \
  --metafits 1099487728.metafits \
  --beam-file mwa_full_embedded_element_pattern.h5 \
  --source-list 1src_offaxis.ao.txt \
  --output-model-files hyp_1src_beam.ms

# ensure MWA keywords exist
for m in hyp_1src_nobeam.ms hyp_1src_beam.ms; do
  docker run --rm -v "$PWD:$PWD" -w "$PWD" mwatelescope/cotter fixmwams "$m" 1099487728.metafits
done
```

### 3) DP3 predict from the same model (beam on/off)
Note: `msin` uses the hyperdrive-simulated no-beam MS for geometry.

```bash
export OPENBLAS_NUM_THREADS=1

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=hyp_1src_nobeam.ms msout=dp3_1src_nobeam.ms steps=[predict] \
  predict.sourcedb=1src_offaxis.skymodel.txt \
  predict.usebeammodel=false \
  msout.overwrite=true

docker run --rm -e OPENBLAS_NUM_THREADS -v "$PWD:$PWD" -w "$PWD" d3vnull0/dp3-mwa:latest DP3 \
  msin=hyp_1src_nobeam.ms msout=dp3_1src_beam.ms steps=[predict] \
  predict.sourcedb=1src_offaxis.skymodel.txt \
  predict.usebeammodel=true \
  predict.coefficients_path=mwa_full_embedded_element_pattern.h5 \
  msout.overwrite=true
```

### 4) Observe the discrepancy
Compute mean(|DATA|) (example uses TAQL; any method is fine):

Expected behavior:
- `dp3_1src_nobeam.ms` ~= `hyp_1src_nobeam.ms`
- `dp3_1src_beam.ms` ~= `hyp_1src_beam.ms`

Observed:
- no-beam matches
- beam differs by ~1e3-1e4 in amplitude.

On one test run:

- hyperdrive: mean(|DATA|) ~ 0.2766 (beam)
- DP3: mean(|DATA|) ~ 0.000170 (beam)

Ratio DP3/hyperdrive ~ 6e-4.

## Direct EveryBeam forward-model sanity check (single row)
A small C++ helper that computes the measurement equation directly using EveryBeam Jones and the MS UVW phase term reproduces hyperdrive's 1-source beam visibilities at the same row+chan, while DP3's predicted visibilities are ~1e-5.

Helper in repo:
- `eb_predict_row.cc` / `run_eb_predict_row.sh`

Example:
```bash
./run_eb_predict_row.sh \
  --ms hyp_1src_beam.ms \
  --obs-ms dp3_1src_beam.ms \
  --beam mwa_full_embedded_element_pattern.h5 \
  --src-ra-deg 14.36753715838882 \
  --src-dec-deg -26.786144247481317 \
  --flux-jy 1 --row 0 --chan 0
```

This prints:
- `Vpred` (EveryBeam forward model)
- `Vobs(ms)` (hyperdrive MS DATA)
- `Vobs(obs-ms)` (DP3 MS DATA)

`Vpred` matches `Vobs(ms)` in magnitude (phase convention differences aside), while `Vobs(obs-ms)` is ~1e4-1e5 smaller.

## Notes / hypotheses
- Not a primary EveryBeam issue: WSClean `-apply-primary-beam` outputs match direct EveryBeam evaluations.
- Not caused by FIELD vs MWA_TILE_POINTING mismatch: patching FIELD.{PHASE_DIR,DELAY_DIR,REFERENCE_DIR} to match MWA_TILE_POINTING.DIRECTION did not change DP3 predicted attenuation.

## Request
Please advise what DP3's `predict.usebeammodel=true` expects for MWA MS metadata and whether it applies:
- a differential beam correction,
- an inverse beam,
- or a specific normalisation mode.

If there is an additional parset key controlling EveryBeam normalisation mode / reference direction handling for MWA, please point to it.
