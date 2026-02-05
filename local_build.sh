sudo apt install liblua5.3-dev libboost1.71-dev libboost-date-time1.71-dev libboost-test1.71-dev libboost-program-options1.71-dev libboost-system1.71-dev libboost-filesystem1.71-dev libhdf5-dev libgsl-dev gcc-10 g++-10 libxml2-dev libpng-dev libcfitsio-dev libfftw3-dev liblua5.3-dev libgtkmm-3.0-dev

export CC=gcc-10
export CXX=g++-10

# install aoflagger (needed since apt version is missing/old or config not found)
cd ~
[ -d aoflagger ] || git clone https://gitlab.com/aroffringa/aoflagger.git
cd aoflagger
# Use a specific version known to work or recent stable
git checkout v3.2.0
[ -d build ] && rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3
make -j`nproc`
sudo make install

# install casacore

cd ~
[ -d casacore ] || git clone https://github.com/casacore/casacore.git
cd casacore
git checkout v3.7.1
[ -d build ] && rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPython3_EXECUTABLE=/usr/bin/python3 -DBUILD_TESTING=OFF -DDATA_DIR=/usr/share/casacore/data
make -j`nproc`
sudo make install

# install everybeam

cd ~
[ -d EveryBeam ] || git clone https://git.astron.nl/RD/EveryBeam.git
cd EveryBeam
git checkout 2614beaf # AO: Fix MWA beam conversion from j2000 to ITRF
[ -d build ] && rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3
make -j`nproc`
sudo make install

# install dp3

cd ~
[ -d DP3 ] || git clone https://github.com/aroffringa/DP3.git
cd DP3
# would look sha d2b78007 "fix-mwa-beam" but it's incompatible with EveryBeam 0.8.0
# sha da0e3f74 "Support EveryBeam 0.8.x" is not yet released
git checkout da0e3f74
[ -d build ] && rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3
make -j`nproc`
sudo make install