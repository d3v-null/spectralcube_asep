## Sources
- https://stellar-h2020.eu/index.php/2023/05/23/introduction-to-lofar-data-processing-tutorial/#:~:text=cal
- https://support.astron.nl/LOFARImagingCookbook/
- https://sagecal.sourceforge.net/tutorial/html/index.html
-


to actually use dp3 with a hyperdrive sky model, need to convert to AO with hyperdrive, then DP3 format with lofartools
## Lofartools

```bash
docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 ls /software/lofartools/build/
addimg
aegean2model
aoop
applymask
bbs2model
checkms
cluster
CMakeCache.txt
CMakeFiles
cmake_install.cmake
colormapper
editmodel
external
fftresample
first2model
fits2png
fitsi
fitsmodel
fitssifit
fitsspectrum
flaglofar
flagnans
flagtimes
imgstats
lbeamedits
makeavgpb
Makefile
matchsources
plottime
refentry
regridimg
render
sensitivity
sourceresponse
unittests
volumes
```

```
editmodel -- Interpolation, extrapolation, plotting and scaling of the spectral energy distribution. Usage:
editmodel
    [-p [-ft]]
    [-rmp]
    [-m <output model>]
    [-o]
    [-s <scale>]
    [-s-to <freq> <flux>]
    [-sp <peakflux A> <freq A> <peakflux B> <freq B>]
    [-sc <intflux A> <freq A> <intflux B> <freq B>]
    [-set0/1/2/3 <flux>]
    [-unpolarized]
    [-pl]
    [-t <threshold>]
    [-tbeam <beamprefix> <threshold-ratio>]
    [-tc <compthreshold>]
    [-tcl <cluster threshold]
    [-r <new-nr-channels>]
    [-ravg <new-nr-channels>]
    [-near/outside <ra> <dec> <dist>]
    [-combine-diff-meas]
    [-collect <name>]
    [-uncollect]
    [-rnd <n> <ra> <dec> <dist>]
    [-sort]
    [-sortbeam <beamprefix>]
    [-lognlogs <frequency> <bincount>]
    [-stats]
    [-setfrequency <val>]
    [-delnans]
    [-from-sagecal <sources-filename> <clusters-filename>]
    [-sagecal <prefix> <chunksize> [-old-sagecal]]
    [-dppp-model <filename>]
    [-skymodel <filename>]
    [-toapp <beamprefix>]
    [-save-clusters <clusters.ann>]
    [-list]
    [-evaluate <freq>]
    [-scale-to <model> <freq-start> <freq-end> <terms>]
    [-select <name>]
    [-search <count> <ra> <dec>]
    [-simuniform N RA Dec dist flux]
    [-simpopulation RA Dec dist lowflux highflux]
    [-min-separation <angle>]
    [-replace-si <n> <si> <terms...>]
    [-set-cluster <name>]
    [-rts <filename>]
    [-to-powerlaw <n>]
    [-shift <ra-angle> <dec-angle>]
    [-kvis <kvis .ann file>]
    [-split/-split2 <ra1> <dec1> <ra2> <dec2>] <model> [<more models...>]

```

### Usage from André
```bash
model_in="images/1069761080-sources-pb.txt"

echo Number of sources in original model: `wc -l ${model_in}`
editmodel -t 0.25 -set-cluster target -skymodel models/target.txt -near 00h00m00.0s -27d00m00s 20deg ${model_in}
echo Number of sources in target: `wc -l models/target.txt`
editmodel -set-cluster south -skymodel models/south.txt -near 00h10m03.077s -59d56m19.53s 7deg ${model_in}
echo Number of sources in south: `wc -l models/south.txt`
editmodel -skymodel models/two-directions.txt models/target.txt models/south.txt
#editmodel -save-clusters models/two-directions-clusters.ann -kvis models/two-directions-kvis.ann models/two-directions.txt

echo Number of sources in two directions: `wc -l models/two-directions.txt`
render -t images/1069761080-MFS-image-pb.fits -o models/two-directions.fits -r models/two-directions.txt
```

### Lofartools container
```bash
singularity pull -F /data/curtin_mwaeor/singularity/lofartools.sif docker://satyapan/lofartools:0.1
```

## DP3

### DP3 gaincal
LOFAR Imaging Cookbook §5.1
```
gaincal.sourcedb= # converted
gaincal.parmdb=gc_solutions.h5 \
gaincal.caltype=fulljones \
gaincal.usebeammodel=true \
gaincal.uvlambdamin=30 \
gaincal.maxiter=300 \
gaincal.tolerance=1e-20 \
gaincal.applysolution=true \
gaincal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
averager.freqresolution=160kHz
```
#### `gaincal.caltype`
![[Screenshot 2025-08-03 at 2.21.52 PM.png]]
#### `gaincal.solint`
- `solint=2` = solutions for every 2 time intervals,


#### DDEs

![[Pasted image 20250805062311.png]]

### DP3 container
```bash
docker build . -f dp3-mwa.Dockerfile --tag d3vnull0/dp3-mwa:latest --push
singularity pull -F /data/curtin_mwaeor/singularity/dp3-mwa.sif docker://d3vnull0/dp3-mwa:latest
```

### DP3 prep 1099490168 iono
```bash
srun -p curtin_mwaeor -N 1 -C nodetype-icx-2048 --exclusive -J 'null' --pty -- /bin/bash -i

# srclist reduction to ao format
cd /data/curtin_mwaeor/nfdata/1099490168/cal; export obsid=1099490168

hyperdrive srclist-by-beam --source-dist-cutoff=180 --veto-threshold 0.005 --metafits ../raw/${obsid}.metafits --number 250 --beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 -o ao /data/curtin_mwaeor/srclist_pumav3_EoR0LoBES_EoR1pietro_CenA-GP_2023-11-07.yaml ${obsid}_reduced_n250.txt

# AO source lists don't support curved-power-law flux densities.
# AO source lists don't support shapelet components.

# srclist conversion
singularity shell -B$PWD -W$PWD /data/curtin_mwaeor/singularity/lofartools.sif
# model_in=1099490168_reduced_n10.txt
model_in=${obsid}_reduced_n250.txt
model_out=${model_in%.txt}.skymodel
singularity exec -B/data -W$PWD docker://satyapan/lofartools:0.1 editmodel -skymodel $model_out $model_in

# clustering?

# ## #
# MS #
# ## #

export uvfits=../prep/birli_1099490168_vv_edg80.ssins.uvfits
export ms=${uvfits%%.uvfits}.ms
export metafits=../raw/1099490168.metafits
singularity exec -B/data -W$PWD --cleanenv docker://d3vnull0/casa casa -c "importuvfits('${uvfits}', '${ms}')"
singularity exec -B/data -W$PWD --cleanenv docker://mwatelescope/cotter fixmwams ${ms} ${metafits}

# gleam style

/usr/bin/time -v hyperdrive di-calibrate \
	--uvw-min 75l --uvw-max 1667l \
	--max-iterations 300 --stop-thresh 1e-20 \
    --source-dist-cutoff=180 --veto-threshold 0.005 \
    --data ../raw/${obsid}.metafits ../prep/birli_${obsid}_vv_edg80.ssins.uvfits \
    --beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
    --source-list $model_in \
    --model-filenames hyp_model_${obsid}_src250.ms \
    --outputs hyp_soln_${obsid}_75l_src250_300it.fits

# User time (seconds): 8582.19
# System time (seconds): 124.95
# Percent of CPU this job got: 2760%
# Elapsed (wall clock) time (h:mm:ss or m:ss): 5:15.46
# Maximum resident set size (kbytes): 34225664

hyperdrive solutions-plot hyp_soln_${obsid}_75l_src250_300it.fits

# transplant

cat >put_model_column.py <<EOF
from casacore.tables import table, tablecolumn, makecoldesc, makearrcoldesc
data = table('$ms', readonly=False)
model = table('hyp_soln_${obsid}_75l_src250_300it.fits', readonly=True)
assert data.getcolshapestring('DATA') == model.getcolshapestring('DATA'), "DATA columns should have same shape"
print("data baselines", [*zip(data.getcol('ANTENNA1'), data.getcol('ANTENNA2'))])
print("model baselines", [*zip(model.getcol('ANTENNA1'), model.getcol('ANTENNA2'))])
assert data.nrows() == model.nrows(), "DATA columns should have same number of rows"
coldesc=makecoldesc('MODEL_DATA', model.getcoldesc('DATA'))
data.addcols(coldesc)
data.putcol('MODEL_DATA', model.getcol('DATA'))
EOF

# this failed: DP3 msin=../prep/birli_1099490168_vv_edg80.ssins.ms msout=dp3_1099490168.ms steps=[filter,gaincal] filter.blrange=[146,3250] gaincal.sourcedb= gaincal.parmdb=gc_solutions.h5 gaincal.caltype=fulljones gaincal.usemodelcolumn=true gaincal.applysolution=true gaincal.usebeammodel=true gaincal.solint=0 gaincal.nchan=1 gaincal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 msout.overwrite=true

# uv minl,maxl = 75,1667, at 154MHz = 1.95m: minm,maxm = 146,3250
export OPENBLAS_NUM_THREADS=1
/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
	msin=$ms \
	msout=dp3_${obsid}.ms \
	steps=[gaincal] \
	gaincal.parmdb=gc_solutions.h5 \
	gaincal.caltype=fulljones \
	gaincal.usemodelcolumn=true \
	gaincal.applysolution=true \
	gaincal.solint=3 \
    gaincal.nchan=1 \
	msout.overwrite=true
singularity exec -B/data -W/data/curtin_mwaeor/nfdata/1099490168/cal docker://d3vnull0/dp3-mwa:latest DP3 msin=../prep/birli_1099490168_vv_edg80.ssins.ms msout=dp3_1099490168.ms steps=[gaincal] gaincal.parmdb=gc_solutions.h5 gaincal.caltype=fulljones gaincal.usemodelcolumn=true gaincal.applysolution=true gaincal.solint=54 gaincal.nchan=1 msout.overwrite=true

# Total DP3 time    5765.08 real     9156.13 user       11162 system
#     0.7% (   37  s) MsReader
#     0.1% ( 6686 ms) Filter filter.
#     0.2% (   11  s) Averager averager.
#    99.0% ( 5704  s) GainCal gaincal.
#            88.4% ( 5042  s) of it spent in predict
#             0.8% (   47  s) of it spent in reordering visibility data
#            10.6% (  606  s) of it spent in estimating gains and computing residuals
#             0.0% (   13 ms) of it spent in writing gain solutions to disk
#         Converged: 3, stalled: 24, non converged: 0, failed: 0
#         Iters converged: 31, stalled: 15, non converged: 0, failed: 0
#     0.0% ( 1220 ms) MSWriter msout.
#       0.0% (    0 ms) Creating task
#     542.3% ( 6618 ms) Writing (threaded)
# User time (seconds): 9156.22
# System time (seconds): 11162.86
# Percent of CPU this job got: 352%
# Elapsed (wall clock) time (h:mm:ss or m:ss): 1:36:08
# Maximum resident set size (kbytes): 70590756

losoto gc_solutions.h5 /data/curtin_mwaeor/src/parsets/losoto.parset

/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
	msin=$ms \
	msout=dp3_${obsid}.ms \
	steps=[filter,averager,gaincal] \
	filter.blrange=[146,3250] \
	averager.timeresolution=4 \
	gaincal.sourcedb=${model_out} \
	gaincal.parmdb=gc_solutions.h5 \
	gaincal.caltype=fulljones \
	gaincal.applysolution=true \
	gaincal.usebeammodel=true \
	gaincal.solint=0 \
    gaincal.nchan=1 \
	gaincal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
	msout.overwrite=true

```

![[Pasted image 20250807063054.png]]
![[Pasted image 20250807063148.png]]
### DP3 prep 1385471344 tid

```bash
giant-squid submit-vis 1385471344 1385470264
# calibrate this one
cd /data/curtin_mwaeor/asvo/909790 ; export obsid=1385470264
# apply it to this one
cd /data/curtin_mwaeor/asvo/909789 ; export obsid=1385471344

singularity shell --nv --env MWA_ASVO_API_KEY=$MWA_ASVO_API_KEY --bind /data --cleanenv --bind /data/curtin_mwaeor/src/MWAEoR-Pipeline/templates:/templates --bind $PWD --workdir $PWD  docker://mwatelescope/mwa-demo:autos_cuda12.5.1

birli -m ${obsid}.metafits ${obsid}_2*.fits -M birli_${obsid}.ms --metrics-out metrics_${obsid}.fits
```

```txt
init duration: 47.319970669s
flag duration: 15.179175384s
write duration: 184.161102516s
correct_digital duration: 2.471302336s
read duration: 9.392826261s
correct_passband duration: 16.20825981s
total duration: 274.732636976s
Estimated data read     =    60ts *    768ch *  10585bl * (32<Jones<f32>> + 4<f32> + 1<bool>) =   16.81 GiB @ 1832.249 MiB/s
Estimated data written  =    60ts *    768ch *  10585bl * 4pol * (8<c32> + 4<f32> + 1<bool>)  =   23.62 GiB @  131.342 MiB/s
```

```bash
# calibrate this one
cd /data/curtin_mwaeor/asvo/909790 ; export obsid=1385470264
hyperdrive srclist-by-beam \
	--source-dist-cutoff=180 --veto-threshold 0.005 \
	--metafits ${obsid}.metafits \
	--number 8000 \
	--beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
	-o ao \
	-- /data/curtin_mwaeor/srclist_pumav3_EoR0LoBES_EoR1pietro_CenA-GP_2023-11-07.yaml \
	${obsid}_reduced_n8000.txt
/usr/bin/time -v hyperdrive di-calibrate -n 8000 --uvw-min 30l --max-iterations 300 --stop-thresh 1e-20 \
    --freq-average 40kHz --source-dist-cutoff=180 --veto-threshold 0.005 \
    --data ${obsid}.metafits birli_${obsid}.ms \
    --beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
    --source-list ${obsid}_reduced_n8000.txt \
    --outputs hyp_soln_${obsid}_30l_src8k_300it.fits
hyperdrive solutions-apply \
    --solutions hyp_soln_${obsid}_30l_src8k_300it.fits \
    --data ${obsid}.metafits ${obsid}.ms \
    --outputs hyp_${obsid}.ms

wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name wsclean_hyp_${obsid} -size 8000 8000 -scale 0.0035502 -channels-out 8 -join-channels -minuv-l 100 -intervals-out 1 -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 1 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam hyp_${obsid}.ms -gridder idg -idg-mode hybrid

singularity exec -B/data -W$PWD docker://satyapan/lofartools:0.1 cluster ${obsid}_reduced_n8000.txt ${obsid}_n8000_c1000.txt 1000

# hyperdrive can't take in clusters :(
hyperdrive di-calibrate -n 1000 --uvw-min 30l --max-iterations 300 --stop-thresh 1e-20 \
    --freq-average 40kHz --source-dist-cutoff=180 --veto-threshold 0.005 \
    --data ${obsid}.metafits birli_${obsid}.ms \
    --beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
    --source-list ${obsid}_n8000_c1000.txt \
    --outputs hyp_soln_${obsid}_30l_src8k_300it_clustered.fits \
	--source-list-type ao
# hyperdrive di-calibrate 0.6.1
# Compiled on git commit hash: 1403ff3
# Error: Source list line 4: Unrecognised keyword cluster
# See for more info: https://MWATelescope.github.io/mwa_hyperdrive/defs/source_lists.html

singularity exec -B/data -W$PWD docker://satyapan/lofartools:0.1 editmodel -skymodel ${obsid}_n8000_c1000.skymodel.txt ${obsid}_n8000_c1000.txt
rm -rf gc_solutions.h5 dp3_${obsid}.ms
/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
	msin=birli_${obsid}.ms \
	msout=dp3_${obsid}.ms \
	steps=[gaincal,averager] \
	gaincal.sourcedb=${obsid}_n8000_c1000.skymodel.txt \
	gaincal.parmdb=gc_solutions.h5 \
	gaincal.caltype=fulljones \
	gaincal.usebeammodel=true \
	gaincal.uvlambdamin=30 \
	gaincal.maxiter=300 \
	gaincal.tolerance=1e-20 \
	gaincal.applysolution=true \
	gaincal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
	averager.freqresolution=160kHz

# Total DP3 time     183288 real      330819 user     42425.6 system
#     0.0% (   14  s) MsReader
#   100.0% (183256  s) GainCal gaincal.
#            97.3% (178355  s) of it spent in predict
#             0.0% (   76  s) of it spent in reordering visibility data
#             2.6% ( 4771  s) of it spent in estimating gains and computing residuals
#             0.0% (   12 ms) of it spent in writing gain solutions to disk
#         Converged: 1, stalled: 51, non converged: 8, failed: 0
#         Iters converged: 0, stalled: 23, non converged: 300, failed: 0
#     0.0% (   32  s) Averager averager.
#     0.0% ( 1039 ms) MSWriter msout.
#       0.0% (    0 ms) Creating task
#     504.4% ( 5241 ms) Writing (threaded)

# User time (seconds): 330818.71
# System time (seconds): 42426.37
# Percent of CPU this job got: 203%
# Elapsed (wall clock) time (h:mm:ss or m:ss): 50:54:51
# Maximum resident set size (kbytes): 72443348

# apply it to this one
cd /data/curtin_mwaeor/asvo/909789 ; export obsid=1385471344
```

### DP3 Workshop04

#### hyperdrive di-cal

```bash
cd /data/curtin_mwaeor/nfdata/1099487728/cal ; export obsid=1099487728

/data/curtin_mwaeor/sw/bin/hyperdrive_clusters srclist-by-beam \
	--metafits ../raw/${obsid}.metafits \
	--number 250 \
	--output-type ao \
	--beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
	/data/curtin_mwaeor/GGSM_updated.fits \
	${obsid}_reduced_n250.txt

singularity exec -B/data -W$PWD docker://satyapan/lofartools:0.1 cluster ${obsid}_reduced_n250.txt ${obsid}_n250_c100.txt 100

/data/curtin_mwaeor/sw/bin/hyperdrive_clusters di-calibrate \
    --uvw-min 75l --uvw-max 1667l \
    --max-iterations 300 --stop-thresh 1e-20 \
     --source-dist-cutoff=180 --veto-threshold 0.005 \
    --data ../raw/${obsid}.metafits ../prep/birli_${obsid}_vv_edg80.ssins.uvfits \
    --time-average 8s --freq-average 80kHz --timesteps-per-timeblock 8s \
    --beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
    --source-list ${obsid}_n250_c100.txt \
    --model-filenames hyp_model_${obsid}_8s_80kHz_src250.ms \
    --outputs hyp_soln_${obsid}_tb8s_80kHz_75-1667l_src250_300it_n250c100.fits \
    --source-list-type ao
# model: 12s, solve: 2:23s

/data/curtin_mwaeor/sw/bin/hyperdrive_clusters solutions-plot hyp_soln_${obsid}_30l_src8k_300it_clustered.fits

wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name hyp_model_${obsid}_src250 -size 8000 8000 -scale 0.0035502 -channels-out 24 -join-channels -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 2 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam hyp_model_${obsid}_src250.ms

/data/curtin_mwaeor/sw/bin/hyperdrive_clusters solutions-apply \
    --data ../raw/${obsid}.metafits ../prep/birli_${obsid}_vv_edg80.ssins.uvfits \
    --solutions hyp_soln_${obsid}_30l_src8k_300it_clustered.fits \
    --timesteps {8..11} \
    --output-vis-time-average 4s \
    --output-vis-freq-average 40kHz \
    --outputs hyp_${obsid}_clusters_16-24s.ms

wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name hyp_${obsid}_clusters_16-24s -size 8000 8000 -scale 0.0035502 -channels-out 24 -join-channels -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 2 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam hyp_${obsid}_clusters_16-24s.ms

/data/curtin_mwaeor/sw/bin/hyperdrive_clusters peel \
	--data hyp_${obsid}_clusters_16-24s.ms \
	--source-list ${obsid}_n250_c100.txt \
	--beam-file /data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
	--iono-sub 50 \
	--num-passes 3 --num-loops 4 \
	--iono-time-average 8s --iono-freq-average 1280kHz \
	--uvw-min 50lambda --uvw-max 1000lambda \
	--short-baseline-sigma 40 --convergence 0.5 \
	--outputs hyp_ionosub50_${obsid}_clusters_16-24s.ms
# 7 seconds

wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name hyp_ionosub50_${obsid}_clusters_16-24s -size 8000 8000 -scale 0.0035502 -channels-out 24 -join-channels -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 2 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam hyp_ionosub50_${obsid}_clusters_16-24s.ms | tee wsclean_hyp_ionosub50_${obsid}_clusters_16-24s.log

singularity exec -B/data -W$PWD docker://satyapan/lofartools:0.1 editmodel -skymodel ${obsid}_n250_c100.skymodel.txt ${obsid}_n250_c100.txt

# wget http://ws.mwatelescope.org/static/mwa_full_embedded_element_pattern.h5
export OPENBLAS_NUM_THREADS=1
/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
  msin=hyp_1099487728_clusters_16-24s.ms \
  msout=dp3_ddesub50_1099490168_t16-24s.ms \
  steps=[ddecal] \
  ddecal.uvlambdamin=75 \
  ddecal.uvlambdamax=1667 \
  ddecal.sourcedb=${obsid}_n250_c100.skymodel.txt \
  ddecal.directions=[$(echo cluster{1..50}|tr ' ' ,)] \
  ddecal.solint=7 \
  ddecal.nchan=1 \
  ddecal.usebeammodel=True \
  ddecal.smoothnessconstraint=4e6 \
  ddecal.beamproximitylimit=300 \
  ddecal.h5parm=dde_solutions.h5 \
  ddecal.subtract=True \
  ddecal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
  msout.overwrite=True
# filter.blrange=[50,1000] breaks the image

# Total DP3 time    3872.77 real     41599.3 user      103679 system
#     0.0% (  463 ms) MsReader
#    99.9% ( 3870  s) DDECal ddecal.
#             1.6% (   61  s) of it spent in predict
#            94.0% ( 3636  s) of it spent in estimating gains and computing residuals
#             0.0% (  495 ms) of it spent in writing gain solutions to disk
#           Substeps taken:
# Iterations taken: [51]
#     0.0% ( 1254 ms) MSWriter msout.
#       0.0% (    0 ms) Creating task
#      36.0% (  451 ms) Writing (threaded)

# cd /data/curtin_mwaeor/src/LiLF; conda activate losoto
python3 scripts/ds9_facet_generator.py --ms \
    /data/curtin_mwaeor/nfdata/1099487728/cal/dp3_ddesub6_1099490168_dde_ssins_30l_src8k_300it_160kHz.ms \
    --imsize 8000 --pixelscale 13 \
    --sourcecatalog /data/curtin_mwaeor/nfdata/1099487728/cal/${obsid}_n250_c100.txt 50 \
    --outputfile /data/curtin_mwaeor/nfdata/1099487728/cal/facets.reg

wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name dp3_ddesub50_1099490168_t16-24s -size 8000 8000 -scale 0.0035502 -channels-out 24 -join-channels -niter 1000000 -mgain 0.5 -gain 0.1 -auto-threshold 2 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam dp3_ddesub50_1099490168_t16-24s.ms

# wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name dp3_ddesub6_1099490168_t16-24s -size 8000 8000 -scale 0.0035502 -channels-out 24 -join-channels -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 2 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam dp3_ddesub6_1099490168_t16-24s.ms

```



### DP3 GainCal

```bash
# DP3 Gaincal (StefCal)
rm -rf gc_solutions.h5 dp3_1099490168_ssins_30l_src8k_160kHz.ms
/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
	msin=$ms \
	msout=dp3_1099490168_ssins_30l_src8k_160kHz.ms \
	steps=[gaincal,averager] \
	gaincal.sourcedb=$model_out \
	gaincal.parmdb=gc_solutions.h5 \
	gaincal.caltype=fulljones \
	gaincal.usebeammodel=true \
	gaincal.uvlambdamin=30 \
	gaincal.maxiter=300 \
	gaincal.tolerance=1e-20 \
	gaincal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5
	averager.freqresolution=160kHz
# this took forever!

#let's try one that's already calibrated and averaged
# - 58.312m = 30λ @ 154.235 MHz
rm -rf gc_solutions.h5 dp3_1099490168_ssins_30l_src8k_160kHz.ms
/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
	msin=../prep/birli_1099490168_vv_edg80.ssins.ms \
	msout=dp3_1099490168_ssins_30l_src8k_160kHz.ms \
	steps=[filter,gaincal,averager] \
	filter.blrange=[58.312,1e10] \
	gaincal.sourcedb=$model_out \
	gaincal.parmdb=gc_solutions.h5 \
	gaincal.caltype=fulljones \
	gaincal.usebeammodel=true \
	gaincal.uvlambdamin=30 \
	gaincal.coefficients_path=/data/curtin_mwaeor/mwa_full_embedded_element_pattern.h5 \
	gaincal.applysolution=true \
	averager.freqresolution=160kHz
```

```txt
Total DP3 time    3331.85 real     4373.91 user     11281.9 system
    0.9% (   29  s) MsReader
    0.2% ( 5370 ms) Filter filter.
   98.9% ( 3293  s) GainCal gaincal.
           58.5% ( 1927  s) of it spent in predict
            0.9% (   29  s) of it spent in reordering visibility data
           39.1% ( 1287  s) of it spent in estimating gains and computing residuals
            0.0% (   11 ms) of it spent in writing gain solutions to disk
        Converged: 2, stalled: 51, non converged: 0, failed: 0
        Iters converged: 0, stalled: 8, non converged: 0, failed: 0
    0.7% (   23  s) Averager averager.
    0.0% (  877 ms) MSWriter msout.
      0.0% (    0 ms) Creating task
    362.9% ( 3184 ms) Writing (threaded)
```

### DP3 DDECal

```bash
export uvfits=hyp_1099490168_ssins_30l_src8k_300it_160kHz.uvfits
export ms=${uvfits%%.uvfits}.ms
export metafits=../raw/1099490168.metafits
singularity exec -B/data -W$PWD --cleanenv docker://d3vnull0/casa casa -c "importuvfits('${uvfits}', '${ms}')"
singularity exec -B/data -W$PWD --cleanenv docker://mwatelescope/cotter fixmwams ${ms} ${metafits}


wget http://ws.mwatelescope.org/static/mwa_full_embedded_element_pattern.h5
rm -rf dp3_1099490168_dde_ssins_30l_src8k_300it_160kHz.ms dde_solutions.h5
/usr/bin/time -v singularity exec -B/data -W$PWD docker://d3vnull0/dp3-mwa:latest DP3 \
  msin=hyp_1099490168_ssins_30l_src8k_300it_160kHz.ms \
  msout=dp3_1099490168_dde_ssins_30l_src8k_300it_160kHz.ms \
  steps=[filter,ddecal] \
  filter.blrange=[60,10000] \
  ddecal.sourcedb=1099490168_reduced_n10.skymodel.txt \
  ddecal.solint=7 \
  ddecal.nchan=1 \
  ddecal.usebeammodel=True \
  ddecal.smoothnessconstraint=4e6 \
  ddecal.beamproximitylimit=300 \
  ddecal.h5parm=dde_solutions.h5 \
  ddecal.coefficients_path=mwa_full_embedded_element_pattern.h5
```

```txt
Total DP3 time    1902.71 real     3434.07 user     12483.1 system
    0.2% ( 4327 ms) MsReader
    0.1% ( 1222 ms) Filter filter.
   99.6% ( 1894  s) DDECal ddecal.
           90.0% ( 1704  s) of it spent in predict
            9.0% (  169  s) of it spent in estimating gains and computing residuals
            0.0% (   26 ms) of it spent in writing gain solutions to disk
          Substeps taken:
Iterations taken: [51,51,51,51,51,51,51,51]
    0.1% ( 2544 ms) MSWriter msout.
     54.4% ( 1384 ms) Creating task
    204.5% ( 5204 ms) Writing (threaded)
```

![[wsclean_dp3_1099490168_dde_ssins_30l_src8k_300it_160kHz-t0001-MFS-image.fits-image-2025-08-03-18-11-36.png]]
```bash
wsclean -taper-inner-tukey 200 -multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs -0.5 -pol i -name wsclean_dp3_1099490168_dde_ssins_30l_src8k_300it_160kHz-t0001 -size 8000 8000 -scale 0.0035502 -channels-out 24 -join-channels -intervals-out 1 -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 1 -auto-mask 5 -mwa-path /data/curtin_mwaeor/ -circular-beam -interval 1 2 dp3_1099490168_dde_ssins_30l_src8k_300it_160kHz.ms
```
![[wsclean_hyp_1099490168_ssins_30l_src8k_300it_160kHz-t0001-MFS-image.fits-image-2025-08-03-18-11-23.png]]
```bash
wsclean -multiscale-gain 0.15 -save-source-list -fit-spectral-pol 2 -nmiter 5 -weight briggs 0.5 -pol i -name wsclean_hyp_1099490168_ssins_30l_src8k_300it_160kHz-t0001 -size 8000 8000 -scale 0.0035502 -channels-out 4 -join-channels -intervals-out 1 -niter 10000000 -mgain 0.5 -gain 0.1 -auto-threshold 1 -auto-mask 5 -mwa-path ... -circular-beam -interval 1 2hyp_1099490168_ssins_30l_src8k_300it_160kHz.ms
```
### Losoto

```bash
conda activate losoto

losoto --help
```
```txt
usage: losoto [-h] [--version] [--quiet] [--verbose] [--filter FILTER] [--info] [--delete DELETE] h5parm [parset]

LoSoTo - Francesco de Gasperin (astro@voo.it)

positional arguments:
  h5parm                H5parm filename.
  parset                LoSoTo parset.

optional arguments:
  -h, --help            show this help message and exit
  --version             show program's version number and exit
  --quiet, -q           Quiet
  --verbose, -V, -v     Verbose
  --filter FILTER, -f FILTER
                        Filter to use with "-i" option to filter on solution set names (default=None)
  --info, -i            List information about h5parm file (default=False). A filter on the solution set names can be specified with the "-f"
                        option.
  --delete DELETE, -d DELETE
                        Specify a solution table to be deleted. Use the solset/soltab sintax.
```

```bash
losoto dde_solutions.h5 /data/curtin_mwaeor/src/parsets/losoto.parset
```

## imaging comparison
```bash
export obsid=1099489064
export obsid=1099490168
wsclean \
-taper-inner-tukey 200 \
-multiscale -multiscale-gain 0.15 -multiscale-scales 0,5,15,30,60 -multiscale-scale-bias 0.4 \
-save-source-list -fit-spectral-pol 2 \
-nmiter 5 -weight briggs -0.5 -pol i \
-name wsclean_dp3_${obsid}_dde_ssins_30l_src8k_300it_160kHz-t0001 \
-size 8000 8000 -scale 0.0035502 \
-channels-out 24 -join-channels \
-intervals-out 1 -niter 10000000 \
-mgain 0.5 -gain 0.1 \
-auto-threshold 1 -auto-mask 5 \
-mwa-path /data/curtin_mwaeor/ \
-circular-beam -interval 1 2 \
dp3_${obsid}_dde_ssins_30l_src8k_300it_160kHz.ms
```