# only on ubuntu 20: Install newer GCC for C++20 support (GCC 11+ required for std::atomic::wait, std::binary_semaphore)
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt update
sudo apt install -y python3-pip python3-pybind11 pybind11-dev liblua5.3-dev libboost1.71-dev libboost-date-time1.71-dev libboost-test1.71-dev libboost-program-options1.71-dev libboost-system1.71-dev libboost-filesystem1.71-dev libhdf5-dev libgsl-dev gcc-11 g++-11 libxml2-dev libpng-dev libcfitsio-dev libfftw3-dev liblua5.3-dev libgtkmm-3.0-dev

# Ensure we have a modern CMake
pip3 install --user "cmake==3.26.4"
export PATH=$HOME/.local/bin:$PATH

export CC=gcc-11
export CXX=g++-11

# Force CMake to use system Python 3.8 instead of pyenv Python 3.11
# This is needed because system pybind11-dev (2.4.3) is incompatible with Python 3.11
export Python3_EXECUTABLE=/usr/bin/python3
export Python3_ROOT_DIR=/usr
# Prevent pyenv and uv from interfering with compilation
unset PYENV_ROOT
unset PYENV_VERSION
unset PYENV_SHELL
unset UV_PYTHON
# Ensure compiler uses system Python headers, not pyenv's or uv's
export CPLUS_INCLUDE_PATH=$(echo "$CPLUS_INCLUDE_PATH" | tr ':' '\n' | grep -v -E '(pyenv|uv/python)' | tr '\n' ':' | sed 's/:$//')
export C_INCLUDE_PATH=$(echo "$C_INCLUDE_PATH" | tr ':' '\n' | grep -v -E '(pyenv|uv/python)' | tr '\n' ':' | sed 's/:$//')
# Explicitly set system Python include directory first
export CPLUS_INCLUDE_PATH=/usr/include/python3.8:${CPLUS_INCLUDE_PATH}
export C_INCLUDE_PATH=/usr/include/python3.8:${C_INCLUDE_PATH}

# install aoflagger (needed since apt version is missing/old or config not found)
cd ~
[ -d aoflagger ] || git clone https://gitlab.com/aroffringa/aoflagger.git
cd aoflagger
# Use a specific version known to work or recent stable
git checkout v3.2.0
[ -d build ] && rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3 -DPython3_EXECUTABLE=/usr/bin/python3 -DPython3_ROOT_DIR=/usr -DPython3_INCLUDE_DIR=/usr/include/python3.8 -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so
make -j`nproc`
sudo make install

# casacore data

sudo mkdir -p /usr/share/casacore/data
sudo chmod 777 /usr/share/casacore/data
cd /usr/share/casacore/data
rsync -avz rsync://casa-rsync.nrao.edu/casa-data .

# install casacore

cd ~
[ -d casacore ] || git clone https://github.com/casacore/casacore.git
cd casacore
git checkout v3.7.1
[ -d build ] && rm -rf build
mkdir build
cd build
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPython3_EXECUTABLE=/usr/bin/python3 -DPython3_ROOT_DIR=/usr -DPython3_INCLUDE_DIR=/usr/include/python3.8 -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so -DBUILD_TESTING=OFF -DDATA_DIR=/usr/share/casacore/data
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
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3 -DPython3_EXECUTABLE=/usr/bin/python3 -DPython3_ROOT_DIR=/usr -DPython3_INCLUDE_DIR=/usr/include/python3.8 -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so
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
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3 -DPython3_EXECUTABLE=/usr/bin/python3 -DPython3_ROOT_DIR=/usr -DPython3_INCLUDE_DIR=/usr/include/python3.8 -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so
make -j`nproc`
sudo make install

# install wsclean

cd ~
[ -d wsclean ] || git clone https://gitlab.com/aroffringa/wsclean.git
cd wsclean
git checkout 7e11958d # everybeam 0.8.0
# Patch CMakeLists.txt to pass Python settings to radler ExternalProject
# Remove any existing Python3 settings first, then add correct ones
sed -i '/-DCMAKE_CXX_FLAGS=${RADLER_CXX_FLAGS}/,/^)$/{ /-DPython3_/d; }' CMakeLists.txt
sed -i '/-DCMAKE_CXX_FLAGS=${RADLER_CXX_FLAGS}/a\    -DPython3_EXECUTABLE=/usr/bin/python3\n    -DPython3_ROOT_DIR=/usr\n    -DPython3_INCLUDE_DIR=/usr/include/python3.8\n    -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so\n    -DPython3_INCLUDE_DIRS=/usr/include/python3.8' CMakeLists.txt
[ -d build ] && rm -rf build
mkdir build
cd build
# Temporarily remove pyenv and uv from PATH to prevent ExternalProject from finding them
OLD_PATH=$PATH
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v -E '(pyenv|\.local/bin.*uv)' | tr '\n' ':' | sed 's/:$//' | sed 's/^://')
cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DPYTHON_EXECUTABLE=/usr/bin/python3 -DPython3_EXECUTABLE=/usr/bin/python3 -DPython3_ROOT_DIR=/usr -DPython3_INCLUDE_DIR=/usr/include/python3.8 -DPython3_LIBRARY=/usr/lib/x86_64-linux-gnu/libpython3.8.so
make -j`nproc`
export PATH=$OLD_PATH
sudo make install
