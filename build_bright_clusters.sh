#!/usr/bin/env bash
set -euo pipefail

# Build a clustered DP3 sky model (patches/directions) for DDECal/Demix.
# Uses lofartools 'cluster' to assign sources to cluster1..clusterN.
#
# Usage:
#   ./build_bright_clusters.sh <ao_model_in> <nclusters> <ao_model_out> <dp3_skymodel_out>
#
# Example:
#   ./build_bright_clusters.sh 1099487728_reduced_n500.txt 5 bright5.ao.txt bright5.skymodel.txt

in_model=${1:?need input AO model (.txt)}
N=${2:?need clustercount}
K=${3:?need number of clusters to select}
ao_out=${4:?need output clustered AO model}
dp3_out=${4:?need output dp3 skymodel}

if [[ ! -s "$in_model" ]]; then
  echo "Missing or empty: $in_model" >&2
  exit 2
fi

# 1) Cluster into K clusters (cluster1..clusterK)
docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
  cluster "$in_model" "$ao_out" "$K"

# 2) Convert clustered AO -> DP3 skymodel
docker run --rm -v "$PWD:$PWD" -w "$PWD" satyapan/lofartools:0.1 \
  editmodel -skymodel "$dp3_out" "$ao_out"

echo "Wrote clustered AO:  $ao_out"
echo "Wrote DP3 skymodel: $dp3_out"
echo "Directions will be named: cluster1..cluster${K}"
