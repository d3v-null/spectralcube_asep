# use mwa-demo to phase the visibilities, without going to wsclean

# CPU: salloc --nodes=1 --partition=mwa --account=mwaeor -t 02:59:59 --exclusive
# . /software/projects/mwaeor/dev/GLEAM-X-pipeline/GLEAM-X-pipeline-setonix.profile

echo "this doesn't work yet"
exit 1

set -x

pipeuser=dev
obsnum=1271676902
debug=
idg=
node=
datadir=/scratch/mwaeor/dev/gama9
cd "${datadir}/${obsnum}" || exit

module load singularity/3.11.4-nohost

mwa_demo_home=/software/projects/mwaeor/dev/mwa-demo
mwa_demo_sif=/software/projects/mwaeor/dev/mwa-demo/mwa-demo_main.sif

cat >ateam.txt <<EOF
HydA ra=9h18m04s,dec=-12d06m41s
EOF

while IFS=' ' read -r source pc; do
    echo "source=$source, pc=$pc"
    echo singularity exec -B "${mwa_demo_home}/demo:/demo" ${mwa_demo_sif} /demo/11_allsky.py \
        --suffix="-$source" \
        --phase-centre "${pc}" \
        --combine-time \
        --combine-freq \
        --pix 51 \
        --img-extent 0.05 \
        $(realpath model.ms)
done < ateam.txt
