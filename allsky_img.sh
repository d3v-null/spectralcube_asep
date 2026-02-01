# allsky image script

# CPU: salloc --nodes=1 --partition=mwa --account=mwaeor -t 02:59:59 --exclusive
# GPU: salloc --nodes=1 --partition=mwa-gpu --account=mwaeor-gpu -t 07:59:59 --exclusive
# . /software/projects/mwaeor/dev/GLEAM-X-pipeline/GLEAM-X-pipeline-setonix.profile


set -x

# Fix for /software mount conflict
module load singularity/3.11.4-nohost

pipeuser=dev
obsnum=1271676902
debug=
idg=
node=
datadir=/scratch/mwaeor/dev/gama9
sourcelist=/software/projects/mwaeor/dev/GLEAM-X-pipeline/models/GGSM_updated.fits
cd "${datadir}/${obsnum}" || exit

echo $GXCONTAINER
if [[ ! -z ${node} ]]
then
    export GXCONTAINER="${GXCONTAINERPATH}/gleamx_tools_${node}.img"
    echo ${GXCONTAINER}
fi

# If obsnum is a file, then we are in an array job
if [[ -f "${obsnum}" ]]
then
    taskid=${SLURM_ARRAY_TASK_ID}
    jobid=${SLURM_ARRAY_JOB_ID}

    echo "obsfile ${obsnum}"
    obsnum=$(sed -n -e "${SLURM_ARRAY_TASK_ID}"p "${obsnum}")
    echo "allsky image obsid ${obsnum}"
else
    taskid=1
    jobid=${SLURM_JOB_ID}
fi

echo "jobid: ${jobid}"
echo "taskid: ${taskid}"



function test_fail {
if [[ $1 != 0 ]]
then
    singularity run ${GXCONTAINER} track_task.py fail --jobid="${jobid}" --taskid="${taskid}" --finish_time="$(date +%s)"
    exit 1
fi
}


# start
singularity run ${GXCONTAINER} track_task.py start --jobid="${jobid}" --taskid="${taskid}" --start_time="$(date +%s)"

metafits="${obsnum}.metafits"
if [[ ! -e ${metafits} ]] || [[ ! -s ${metafits} ]]
then
    wget -O "${metafits}" "http://ws.mwatelescope.org/metadata/fits?obs_id=${obsnum}"
    test_fail $?
fi

# chgcenter to minimize w layers
module load wsclean/3.4-idg
# I needed this to get TAI_UTC update
# mkdir -p /scratch/mwaeor/dev/casacore_data && \
# cd /scratch/mwaeor/dev/casacore_data && \
# wget -nv ftp://ftp.astron.nl/outgoing/Measures/WSRT_Measures.ztar && \
# tar -zxf WSRT_Measures.ztar && \
# rm WSRT_Measures.ztar

current=$(chgcentre "${obsnum}.ms")
echo $current
# Current phase direction: 09h00m00.0s 00d30m00s
# Zenith is at: 09h29m26.263s -26d27m25.968s (09h28m30.159s -26d27m26.955s - 09h30m22.368s -26d27m24.986s)
# Min-w direction is at: 09h29m38.14s -26d42m33.982s

chgcentre -minw "${obsnum}.ms"
# Processing field "": 09h00m00.0s 00d30m00s -> 09h29m38.14s -26d42m33.982s (28.1296 deg)

# Old uvw: [0, 0, 0] (0)
# New [0, 0, 0] (0)

# Old uvw: [-221.91, 148.354, 106.469] (287.382)
# New [-233.625, 167.356, 0.481338] (287.382)

# Old uvw: [-30.9451, 42.2622, 26.2066] (58.5703)
# New [-34.0201, 47.6767, 0.220601] (58.5703)

# Old uvw: [-134.973, 181.994, 112.046] (252.772)
# New [-148.096, 204.845, 0.040282] (252.772)

# Old uvw: [-186.729, 341.838, 200.214] (437.958)
# New [-210.616, 383.988, -1.25675] (437.958)

# do allsky image
chansout=64
datacolumn=DATA
export imsize=2048
scale=$(echo "120.0 / ${imsize}" | bc -l | awk '{printf "%.6f", $1}')
echo "scale: ${scale}"
wsclean -name "${obsnum}_allsky" \
    -size ${imsize} ${imsize} -scale ${scale} \
    -channels-out ${chansout} -join-channels \
    -parallel-gridding ${SLURM_CPUS_PER_TASK:-16} \
    -temp-dir /tmp \
    -pol xx,yy \
    -niter 0 \
    -weight natural \
    -data-column ${datacolumn} \
    "${obsnum}.ms"
# -minuv-l 100 ?


module load hyperdrive/0.6.1-cpu
# or module load hyperdrive/0.6.1

hyperdrive srclist-by-beam \
    --metafits ${metafits} \
    --number 100 \
    ${sourcelist} \
    -- srclist_100.fits

# hyperdrive vis-simulate \
#     --metafits ${metafits} \
#     --source-list ${sourcelist} \
#     --num-sources 1000 \
#     --freq-res 80 \
#     --time-res 8 \
#     --output-model-files model.ms

# chgcentre -minw model.ms
# wsclean -name "model_allsky" \
#     -size ${imsize} ${imsize} -scale ${scale} \
#     -channels-out ${chansout} -join-channels \
#     -parallel-gridding ${SLURM_CPUS_PER_TASK:-16} \
#     -temp-dir /tmp \
#     -pol xx,yy \
#     -niter 0 \
#     -weight natural \
#     -data-column ${datacolumn} \
#     "model.ms"

# hyperdrive-peel 0.6.1
# Solve for and subtract ionospheric sky-model.
# https://mwatelescope.github.io/mwa_hyperdrive/user/peel/intro.html

hyperdrive peel \
    --data ${metafits} ${obsnum}.ms \
    --source-list ${sourcelist} \
    --num-sources 1000 \
    --iono-sub 100 \
    --output iono.json iono.ms

# GLEAM J084125-754033 (130.357°, -75.676°): -1.34706e-5 -1.77750e-5 0.666
# GLEAM J090225-051639 (135.606°,  -5.278°): +3.70896e-5 -2.11495e-5 0.933
# GLEAM J085328-034104 (133.367°,  -3.685°): +4.28916e-5 -2.24228e-5 0.916
# GLEAM J094746+072509 (146.944°,   7.419°): +3.84766e-5 -5.55030e-5 1.698
# GLEAM J123049+122321 (187.706°,  12.389°): +4.79076e-6 -4.82184e-5 1.056
# GLEAM J093631+042207 (144.133°,   4.369°): +3.09004e-5 -4.23855e-5 1.135
# GLEAM J085711-033940 (134.298°,  -3.661°): +1.73878e-5 -3.34803e-5 0.607
# GLEAM J040848-750716 ( 62.203°, -75.121°): -2.51867e-5 +1.64382e-5 0.428
# GLEAM J063547-751617 ( 98.947°, -75.271°): -1.10883e-5 -1.04926e-5 0.558
# GLEAM J090147-255516 (135.447°, -25.921°): +3.61195e-5 -8.58567e-7 0.652

# but on the gpu version
# GLEAM J084125-754033 (130.357°, -75.676°): -1.34328e-5 -1.78061e-5 0.666
# GLEAM J090225-051639 (135.606°,  -5.278°): +3.74779e-5 -2.10164e-5 0.934
# GLEAM J085328-034104 (133.367°,  -3.685°): +4.23470e-5 -2.21368e-5 0.927
# GLEAM J094746+072509 (146.944°,   7.419°): +0.00000e0 +0.00000e0 1.000
# GLEAM J123049+122321 (187.706°,  12.389°): +5.71854e-6 -4.05470e-5 1.062
# GLEAM J093631+042207 (144.133°,   4.369°): +3.09412e-5 -4.24102e-5 1.131
# GLEAM J085711-033940 (134.298°,  -3.661°): +1.70947e-5 -3.43519e-5 0.604
# GLEAM J040848-750716 ( 62.203°, -75.121°): -2.56458e-5 +1.63957e-5 0.427
# GLEAM J063547-751617 ( 98.947°, -75.271°): -1.08784e-5 -1.11941e-5 0.559
# GLEAM J090147-255516 (135.447°, -25.921°): +3.46609e-5 -3.39370e-7 0.654


chgcentre -minw iono.ms
wsclean -name "iono_allsky" \
    -size ${imsize} ${imsize} -scale ${scale} \
    -channels-out ${chansout} -join-channels \
    -parallel-gridding ${SLURM_CPUS_PER_TASK:-16} \
    -temp-dir /tmp \
    -pol xx,yy \
    -niter 0 \
    -weight natural \
    -data-column ${datacolumn} \
    -intervals-out 15 \
    "iono.ms"

# ffmpeg -pattern_type glob \
#   -i 'iono_allsky-t*-MFS-XX-image.fits-image-*.png' \
#   -filter_complex "[0:v]split[a][b];[b]reverse[b];[a][b]concat=n=2:v=1:a=0,format=yuv420p" \
#   -loop 0 iono_allsky-MFS-XX-image.gif


# ------------------------------------------------------------------------------
# DP3 Extension: Cluster, DDEcal, Subtract, Image
# ------------------------------------------------------------------------------

echo "DP3 processing does not work yet"
exit 1

NSRC=100
NCLUSTERS=10
MWA_BEAM_FILE="/software/projects/mwaeor/dev/GLEAM-X-pipeline/data/mwa_pb/mwa_full_embedded_element_pattern.h5"
LOFARTOOLS="docker://satyapan/lofartools:0.1"
DP3_IMAGE="docker://d3vnull0/dp3-mwa:latest"

# 1. Generate source list in AO format (using AO format directly for lofartools)
hyperdrive srclist-by-beam \
    --metafits ${metafits} \
    --number ${NSRC} \
    --output-type ao \
    ${sourcelist} \
    -- ${obsnum}_src${NSRC}.txt

# 2. Cluster the source list
echo "Clustering sources..."
singularity exec -B $PWD ${LOFARTOOLS} cluster ${obsnum}_src${NSRC}.txt ${obsnum}_c${NCLUSTERS}.txt ${NCLUSTERS}

# 3. Convert to skymodel
echo "Converting to skymodel..."
singularity exec -B $PWD ${LOFARTOOLS} editmodel -skymodel ${obsnum}_c${NCLUSTERS}.skymodel ${obsnum}_c${NCLUSTERS}.txt

# 4. DP3 DDECal and Subtract
echo "Running DP3 DDEcal and subtraction..."
DP3_MSOUT="dp3_${obsnum}.ms"
rm -rf ${DP3_MSOUT}

# Construct directions string: cluster1,cluster2,...,clusterN
CLUSTERS=$(seq -s, -f "cluster%g" 1 ${NCLUSTERS})

singularity exec -B $PWD --env OPENBLAS_NUM_THREADS=1 ${DP3_IMAGE} DP3 \
    msin=${obsnum}.ms \
    msout=${DP3_MSOUT} \
    steps=[ddecal] \
    ddecal.sourcedb=${obsnum}_c${NCLUSTERS}.skymodel \
    ddecal.directions=[${CLUSTERS}] \
    ddecal.subtract=True \
    ddecal.h5parm=${obsnum}_dde.h5 \
    ddecal.solint=4 \
    ddecal.nchan=1 \
    ddecal.usebeammodel=True \
    ddecal.coefficients_path=${MWA_BEAM_FILE} \
    msout.overwrite=True

# 5. Image the result (residuals)
echo "Imaging DP3 output..."
chgcentre -minw ${DP3_MSOUT}

wsclean -name "${obsnum}_dp3_allsky" \
    -size ${imsize} ${imsize} -scale ${scale} \
    -channels-out ${chansout} -join-channels \
    -parallel-gridding ${SLURM_CPUS_PER_TASK:-16} \
    -temp-dir /tmp \
    -pol xx,yy \
    -niter 0 \
    -weight natural \
    -data-column DATA \
    "${DP3_MSOUT}"
