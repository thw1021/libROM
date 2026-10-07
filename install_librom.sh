#!/usr/bin/env bash
#
# libROM full-feature build & installation script.
#
# Reproduces the upstream build path (scripts/setup.sh + scripts/compile.sh)
# with local dependencies under dependencies/:
#   1. ScaLAPACK 2.2.0  (static, -fPIC)          -> dependencies/scalapack-2.2.0
#   2. HYPRE 2.28.0     (static, -fPIC, MPI)     -> dependencies/hypre/src/hypre
#   3. ParMETIS 4.0.3   (shared, PIC metis)      -> dependencies/parmetis-4.0.3/build
#   4. MFEM 4.7         (parallel shared, -fPIC) -> dependencies/mfem_parallel
#   5. googletest 1.14.0                         -> dependencies/googletest/install
#   6. libROM full shared build  (MFEM + examples + unit tests) -> build/
#   7. libROM PIC static core build (for linking into SU2 shared objects) -> build_pic/
#   7b. SU2 HDF5 version alignment of build_pic (conditional; install_su2.sh
#       also performs this during the SU2 build -- see Step 8b)
#   8. Environment setup script                  -> librom_env.sh
#
# Every dependency step is skipped when its artifact already exists, so the
# script can be re-run to only rebuild what changed.

set -e

print_info()    { echo -e "\033[1;34m[INFO]\033[0m $1"; }
print_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $1"; }
print_error()   { echo -e "\033[1;31m[ERROR]\033[0m $1"; }
print_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }

LIBROM_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPS_DIR="${LIBROM_DIR}/dependencies"
BUILD_DIR="${LIBROM_DIR}/build"          # full shared build (MFEM + examples + tests)
BUILD_PIC_DIR="${LIBROM_DIR}/build_pic"  # PIC static core build (SU2)
ENV_FILE="${LIBROM_DIR}/librom_env.sh"
NPROC="${LIBROM_JOBS:-$(nproc)}"   # override with LIBROM_JOBS (SU2 convention: compile with <= 10 cores)

# HDF5 built with MPI support is required (HDFDatabaseMPIO uses H5Pset_fapl_mpio).
# SU2 additionally requires the PIC static core (build_pic) to be compiled
# against the SAME HDF5 that SU2's CGNS vendors (libsu2hdf5.a, 1.12.1):
# HDF5's H5check_version aborts on any header/library mismatch. See Step 8b.
FLEXI_HDF5="/home/tang/packages/flexi/share/GNU-MPI/HDF5/build/src/HDF5-build"

MISSING_DEPS=()

check_dependency() {
    local cmd=$1
    local name=$2
    local pkg=$3
    if command -v "$cmd" &>/dev/null; then
        print_success "$name found: $(command -v "$cmd")"
    else
        print_warning "$name not found"
        MISSING_DEPS+=("$name ($pkg)")
    fi
}

print_info "=========================================="
print_info "      libROM Installation Script"
print_info "=========================================="
print_info "Mode: full build (MFEM + examples + unit tests + PIC static core)"
print_info "libROM directory: $LIBROM_DIR"
echo ""

print_info "Step 1: Checking required dependencies..."

check_dependency mpicc  "MPI (mpicc)"  "libopenmpi-dev openmpi-bin"
check_dependency mpicxx "MPI (mpicxx)" "libopenmpi-dev openmpi-bin"
check_dependency mpif90 "MPI (mpif90)" "libopenmpi-dev openmpi-bin"
check_dependency cmake  "CMake (>= 3.12)" "cmake"
check_dependency gcc    "GCC" "gcc"
check_dependency g++    "G++" "g++"

print_info "Checking BLAS/LAPACK/ZLIB..."
for lib in libblas liblapack libz; do
    if ldconfig -p | grep -q "$lib"; then
        print_success "$lib found"
    else
        print_warning "$lib not found"
        MISSING_DEPS+=("$lib")
    fi
done

print_info "Checking HDF5 (parallel)..."
HDF5_ROOT=""
HDF5_LIB_DIR=""
if command -v h5cc &>/dev/null; then
    print_success "HDF5 found: $(command -v h5cc)"
    HDF5_ROOT="$(dirname "$(dirname "$(command -v h5cc)")")"
elif [ -f "${FLEXI_HDF5}/bin/h5cc" ]; then
    print_success "HDF5 found (flexi, parallel): ${FLEXI_HDF5}/bin/h5cc"
    HDF5_ROOT="${FLEXI_HDF5}"
else
    print_error "HDF5 not found"
    MISSING_DEPS+=("HDF5 (libhdf5-openmpi-dev hdf5-tools)")
fi
# Locate the actual HDF5 library directory. A normal install has it under
# ${HDF5_ROOT}/lib; the flexi build tree keeps the libraries two levels above
# the HDF5-build directory (.../HDF5/build/lib instead of .../HDF5-build/lib).
if [ -n "${HDF5_ROOT}" ]; then
    for cand in "${HDF5_ROOT}/lib" "$(dirname "$(dirname "${HDF5_ROOT}")")/lib"; do
        if ls "${cand}"/libhdf5.* >/dev/null 2>&1; then
            HDF5_LIB_DIR="${cand}"
            break
        fi
    done
    [ -n "${HDF5_LIB_DIR}" ] || { print_error "HDF5 libraries not found under ${HDF5_ROOT}"; MISSING_DEPS+=("HDF5 libraries"); }
fi

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    print_error "The following required dependencies are missing:"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo ""
    print_info "Please install them first using:"
    print_info "  sudo apt-get install libopenmpi-dev openmpi-bin cmake gcc g++ libblas-dev liblapack-dev zlib1g-dev libhdf5-openmpi-dev hdf5-tools"
    echo ""
    print_error "Installation aborted."
    exit 1
fi

print_success "All required system dependencies are installed."
echo ""

export CC=mpicc
export CXX=mpicxx
export FC=mpif90

# ============================================================================
# Step 2: ScaLAPACK (static, must be PIC: it is linked into libROM.so)
# ============================================================================
print_info "Step 2: ScaLAPACK 2.2.0..."

SCALAPACK_DIR="${DEPS_DIR}/scalapack-2.2.0"
if [ -f "${SCALAPACK_DIR}/libscalapack.a" ]; then
    print_success "ScaLAPACK already built: ${SCALAPACK_DIR}/libscalapack.a"
else
    cd "$DEPS_DIR"
    [ -d "${SCALAPACK_DIR}" ] || tar -zxf scalapack-2.2.0.tar.gz
    [ -f "${SCALAPACK_DIR}/SLmake.inc" ] || cp "${DEPS_DIR}/SLmake.inc" "${SCALAPACK_DIR}/"
    cd "${SCALAPACK_DIR}"
    print_info "Compiling ScaLAPACK..."
    make -j${NPROC} > /dev/null 2>&1 || make -j2
    [ -f "libscalapack.a" ] || { print_error "ScaLAPACK compilation failed"; exit 1; }
    print_success "ScaLAPACK compiled successfully"
fi

# ============================================================================
# Step 3: HYPRE (static with -fPIC; it is embedded into libmfem.so)
# ============================================================================
print_info "Step 3: HYPRE 2.28.0..."

HYPRE_PREFIX="${DEPS_DIR}/hypre/src/hypre"
if [ -f "${HYPRE_PREFIX}/lib/libHYPRE.a" ]; then
    print_success "HYPRE already built: ${HYPRE_PREFIX}/lib/libHYPRE.a"
else
    cd "$DEPS_DIR"
    if [ ! -f "v2.28.0.tar.gz" ]; then
        print_info "Downloading HYPRE 2.28.0..."
        wget -q https://github.com/hypre-space/hypre/archive/v2.28.0.tar.gz
    fi
    if [ ! -d "hypre/src" ]; then
        print_info "Extracting HYPRE..."
        rm -rf hypre-2.28.0 hypre
        tar -xzf v2.28.0.tar.gz
        mv hypre-2.28.0 hypre
    fi
    cd hypre/src
    if [ ! -f "config.status" ]; then
        print_info "Configuring HYPRE (MPI, -fPIC, no Fortran)..."
        CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" ./configure --disable-fortran CC=mpicc CXX=mpicxx
    fi
    print_info "Compiling HYPRE..."
    make -j${NPROC} > /dev/null 2>&1
    [ -f "${HYPRE_PREFIX}/lib/libHYPRE.a" ] || { print_error "HYPRE compilation failed"; exit 1; }
    print_success "HYPRE compiled successfully"
fi

# ============================================================================
# Step 4: ParMETIS (shared=1 like upstream scripts/setup.sh; -fPIC so the
#          static libmetis.a can be linked into shared objects)
# ============================================================================
print_info "Step 4: ParMETIS 4.0.3..."

PARMETIS_DIR="${DEPS_DIR}/parmetis-4.0.3"
if [ -f "${PARMETIS_DIR}/build/lib/libparmetis/libparmetis.so" ]; then
    print_success "ParMETIS already built: ${PARMETIS_DIR}/build/lib/libparmetis/libparmetis.so"
else
    cd "$PARMETIS_DIR"
    print_info "Configuring ParMETIS (shared=1, -fPIC)..."
    rm -rf build
    CFLAGS="-fPIC -O3" make config shared=1 cc=mpicc cxx=mpicxx
    print_info "Compiling ParMETIS..."
    make -j${NPROC} > /dev/null 2>&1
    ( cd build && ln -sfn Linux-x86_64 lib )
    [ -f "build/lib/libparmetis/libparmetis.so" ] || { print_error "ParMETIS compilation failed"; exit 1; }
    print_success "ParMETIS compiled successfully"
fi

# ============================================================================
# Step 5: MFEM 4.7 (parallel, shared, -fPIC) — same make invocation as
#         upstream scripts/setup.sh
# ============================================================================
print_info "Step 5: MFEM 4.7 (parallel, shared)..."

MFEM_DIR="${DEPS_DIR}/mfem_parallel"
if [ -f "${MFEM_DIR}/libmfem.so.4.7" ]; then
    print_success "MFEM already built: ${MFEM_DIR}/libmfem.so.4.7"
else
    if [ ! -d "$MFEM_DIR" ]; then
        print_error "MFEM source not found at ${MFEM_DIR}."
        print_info "Clone it: git clone https://github.com/mfem/mfem.git ${MFEM_DIR}"
        print_info "Then checkout v4.7 (commit dc9128ef596e84daf1138aa3046b826bba9d259f)"
        exit 1
    fi
    cd "$MFEM_DIR"
    print_info "Compiling MFEM (this takes a few minutes)..."
    make -j${NPROC} parallel CPPFLAGS="-fPIC" STATIC=NO SHARED=YES \
        MFEM_USE_MPI=YES MFEM_USE_GSLIB=NO MFEM_USE_LAPACK=NO \
        MFEM_USE_METIS=YES MFEM_USE_METIS_5=YES \
        METIS_DIR="${PARMETIS_DIR}" \
        METIS_OPT="-I${PARMETIS_DIR}/metis/include" \
        METIS_LIB="-L${PARMETIS_DIR}/build/lib/libparmetis -lparmetis -L${PARMETIS_DIR}/build/lib/libmetis -lmetis" \
        MFEM_USE_SUPERLU=NO SUPERLU_DIR= SUPERLU_OPT= SUPERLU_LIB= \
        > /dev/null 2>&1
    [ -f "libmfem.so.4.7" ] || { print_error "MFEM compilation failed"; exit 1; }
    print_success "MFEM compiled successfully"
fi
# libROM's CMake looks for MFEM under dependencies/mfem
( cd "$DEPS_DIR" && ln -sfn mfem_parallel mfem )

# ============================================================================
# Step 6: googletest (for unit tests; optional, falls back to ENABLE_TESTS=OFF)
# ============================================================================
print_info "Step 6: googletest (unit tests)..."

GTEST_DIR="${DEPS_DIR}/googletest"
GTEST_INSTALL="${GTEST_DIR}/install"
ENABLE_TESTS=OFF
if [ -f "${GTEST_INSTALL}/lib/libgtest.a" ]; then
    print_success "googletest already installed: ${GTEST_INSTALL}"
    ENABLE_TESTS=ON
elif ldconfig -p | grep -q libgtest && [ -d /usr/include/gtest ]; then
    print_success "googletest found on the system"
    ENABLE_TESTS=ON
else
    print_info "googletest not found; downloading v1.14.0..."
    if mkdir -p "${GTEST_DIR}" && cd "${GTEST_DIR}" && \
       curl -sL --max-time 120 -o v1.14.0.tar.gz https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz && \
       tar -xzf v1.14.0.tar.gz && mkdir -p build && cd build && \
       cmake ../googletest-1.14.0 -DCMAKE_BUILD_TYPE=Release \
             -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
             -DCMAKE_INSTALL_PREFIX="${GTEST_INSTALL}" > /dev/null 2>&1 && \
       make -j${NPROC} > /dev/null 2>&1 && make install > /dev/null 2>&1; then
        print_success "googletest installed: ${GTEST_INSTALL}"
        ENABLE_TESTS=ON
    else
        print_warning "Could not install googletest; unit tests will be disabled"
        ENABLE_TESTS=OFF
    fi
fi

# ============================================================================
# Step 7: libROM full shared build (MFEM + examples + regression + unit tests)
# ============================================================================
print_info "Step 7: Building libROM (full, shared, MFEM enabled)..."

print_info "Features: DMD/DMDc/AdaptiveDMD/NonuniformDMD/SnapshotDMD, SVD (static,"
print_info "incremental, randomized), DEIM/GNAT/QDEIM/S_OPT/STSampling, greedy"
print_info "sampling, manifold interpolation, MFEM interface, examples, tests."
echo ""

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

CMAKE_ARGS=(
    -DCMAKE_BUILD_TYPE=Release
    -DUSE_MFEM=ON
    -DMFEM_USE_GSLIB=OFF
    -DBUILD_STATIC=OFF
    -DENABLE_EXAMPLES=ON
    -DENABLE_TESTS=${ENABLE_TESTS}
    -DCMAKE_C_COMPILER=mpicc
    -DCMAKE_CXX_COMPILER=mpicxx
    -DCMAKE_Fortran_COMPILER=mpif90
    -DCMAKE_INSTALL_PREFIX="${BUILD_DIR}"
)
if [ -n "$HDF5_ROOT" ]; then
    CMAKE_ARGS+=("-DHDF5_ROOT=${HDF5_ROOT}")
fi
if [ "${ENABLE_TESTS}" = "ON" ] && [ -f "${GTEST_INSTALL}/lib/libgtest.a" ]; then
    CMAKE_ARGS+=("-DGTest_ROOT=${GTEST_INSTALL}")
fi

# ScaLAPACK is discovered through the SCALAPACKDIR environment variable
# (see cmake/modules/FindScaLAPACK.cmake).
export SCALAPACKDIR="${SCALAPACK_DIR}"
# Pin ParMETIS to our own build so the system package (/lib/libparmetis.so)
# is not picked up instead.
CMAKE_ARGS+=("-DPARMETIS_DIR=${PARMETIS_DIR}/build/lib")

print_info "Running cmake..."
cmake "${LIBROM_DIR}" "${CMAKE_ARGS[@]}"

print_info "Compiling libROM (this takes a few minutes)..."
make -j${NPROC} > /dev/null 2>&1
make install > /dev/null 2>&1

[ -f "${BUILD_DIR}/lib/libROM.so" ] || { print_error "libROM.so not found in ${BUILD_DIR}/lib"; exit 1; }
print_success "libROM shared library built: ${BUILD_DIR}/lib/libROM.so"
print_success "Headers installed: ${BUILD_DIR}/include"

# ============================================================================
# Step 8: libROM PIC static core build (no MFEM; for SU2 shared objects)
# ============================================================================
print_info "Step 8: Building libROM (PIC static core, no MFEM)..."

# Position-independent code is REQUIRED because SU2 links libROM.a into the
# Python wrapper shared object (_pysu2.so / _pysu2ad.so). Without -fPIC, the
# linker fails: "relocation R_X86_64_PC32 ... can not be used when making a
# shared object; recompile with -fPIC". CMAKE_POSITION_INDEPENDENT_CODE=ON is
# the CMake-standard way to add -fPIC to a STATIC library build.
rm -rf "${BUILD_PIC_DIR}"
mkdir -p "${BUILD_PIC_DIR}"
cd "${BUILD_PIC_DIR}"

cmake "${LIBROM_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_MFEM=OFF \
    -DBUILD_STATIC=ON \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_TESTS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_COMPILER=mpicc \
    -DCMAKE_CXX_COMPILER=mpicxx \
    -DCMAKE_Fortran_COMPILER=mpif90 \
    ${HDF5_ROOT:+-DHDF5_ROOT=${HDF5_ROOT}} \
    -DCMAKE_INSTALL_PREFIX="${BUILD_PIC_DIR}" \
    > /dev/null 2>&1

make -j${NPROC} > /dev/null 2>&1
make install > /dev/null 2>&1

[ -f "${BUILD_PIC_DIR}/lib/libROM.a" ] || { print_error "libROM.a not found in ${BUILD_PIC_DIR}/lib"; exit 1; }
print_success "libROM PIC static library built: ${BUILD_PIC_DIR}/lib/libROM.a"
print_success "Headers installed: ${BUILD_PIC_DIR}/include"

# ============================================================================
# Step 8b: SU2 HDF5 version alignment (conditional)
# ============================================================================
# SU2's CGNS links the HDF5 vendored inside the SU2 build tree (libsu2hdf5.a,
# HDF5 1.12.1, MPI-enabled), and libROM's H5 references resolve to that same
# static code inside the SU2 binary. HDF5's H5check_version() aborts the
# process on ANY header/library version mismatch, so the build_pic/lib/libROM.a
# produced above (compiled against the flexi HDF5 1.12.0) would make SU2_CFD
# abort at the first ROM sample (SAVE_LIBROM=YES): "Headers are 1.12.0,
# library is 1.12.1". install_su2.sh performs this alignment automatically
# during the SU2 build; here we only re-align early when an SU2 build tree
# already exists (libROM refresh scenario).
SU2_HOME_EFF="${SU2_HOME:-/home/tang/packages/SU2}"
VENDORED_HDF5_A="${SU2_HOME_EFF}/build/externals/cgns/hdf5/libsu2hdf5.a"
SU2_RECIPE="${SU2_HOME_EFF}/nemo_validation/verification/scripts/deps_rebuild_librom_vendored_hdf5.sh"
LIBROM_ALIGNED=false
if [ -f "${VENDORED_HDF5_A}" ] && [ -f "${SU2_RECIPE}" ]; then
    print_info "Step 8b: SU2 vendored HDF5 found - re-aligning build_pic/lib/libROM.a"
    if JOBS="${NPROC}" bash "${SU2_RECIPE}"; then
        print_success "libROM.a aligned with the SU2 vendored HDF5 (1.12.1, libsu2hdf5.a)"
        LIBROM_ALIGNED=true
    else
        print_error "SU2 HDF5 alignment failed - SU2 SAVE_LIBROM would abort; fix the recipe error above"
        exit 1
    fi
else
    print_warning "Step 8b: SU2 build tree (libsu2hdf5.a) not found - skipping early HDF5 alignment."
    print_warning "Expected on a fresh machine: install_su2.sh performs the alignment automatically"
    print_warning "during the SU2 build. Manual command:"
    print_warning "  bash ${SU2_RECIPE}"
fi

# ============================================================================
# Step 9: Generate environment setup script
# ============================================================================
print_info "Step 9: Generating environment setup script..."

# HDF5 linkage flags for standalone consumers of the PIC static core. When the
# archive is aligned with the SU2 vendored HDF5, point at that static library;
# otherwise fall back to the flexi parallel HDF5 used in Step 8.
if [ "${LIBROM_ALIGNED}" = true ]; then
    STATIC_HDF5_FLAGS="-L${SU2_HOME_EFF}/build/externals/cgns/hdf5 -lsu2hdf5"
    HDF5_NOTE="aligned with the SU2 vendored HDF5 1.12.1 (libsu2hdf5.a)"
else
    STATIC_HDF5_FLAGS="-Wl,-rpath,${HDF5_LIB_DIR} -L${HDF5_LIB_DIR} -lhdf5"
    HDF5_NOTE="flexi parallel HDF5 (not aligned with SU2; re-run this script after building SU2)"
fi

cat > "$ENV_FILE" << EOF
#!/usr/bin/env bash
# Generated by install_librom.sh — full-feature libROM environment.
#
# Two libraries are available:
#   1. Full shared build (MFEM enabled, examples/tests):  \$LIBROM_LDFLAGS
#   2. PIC static core build (no MFEM, for SU2):          \$LIBROM_STATIC_LDFLAGS

export LIBROM_DIR="${LIBROM_DIR}"
export LIBROM_BUILD_DIR="${BUILD_DIR}"
export LIBROM_LIB_DIR="${BUILD_DIR}/lib"
export LIBROM_INCLUDE_DIR="${BUILD_DIR}/include"

# PIC static core (SU2)
export LIBROM_PIC_BUILD_DIR="${BUILD_PIC_DIR}"
export LIBROM_STATIC_LIB_DIR="${BUILD_PIC_DIR}/lib"
export LIBROM_STATIC_INCLUDE_DIR="${BUILD_PIC_DIR}/include"

# Dependencies
export MFEM_DIR="${DEPS_DIR}/mfem"
export HYPRE_DIR="${DEPS_DIR}/hypre/src/hypre"
export SCALAPACK_DIR="${SCALAPACK_DIR}"
export PARMETIS_LIB_DIR="${PARMETIS_DIR}/build/lib/libparmetis"
export LIBROM_HDF5_ROOT="${HDF5_ROOT}"

# Header search paths
export CPATH="${BUILD_DIR}/include:\${CPATH}"
export C_INCLUDE_PATH="${BUILD_DIR}/include:\${C_INCLUDE_PATH}"
export CPLUS_INCLUDE_PATH="${BUILD_DIR}/include:\${CPLUS_INCLUDE_PATH}"

# Needed when including libROM's MFEM-dependent headers (mfem/PointwiseSnapshot.hpp)
export LIBROM_MFEM_CFLAGS="-I${DEPS_DIR}/mfem -I${DEPS_DIR}/hypre/src/hypre/include"

# Library search / runtime paths
export LIBRARY_PATH="${BUILD_DIR}/lib:${SCALAPACK_DIR}:\${LIBRARY_PATH}"
export LD_LIBRARY_PATH="${BUILD_DIR}/lib:${DEPS_DIR}/mfem:${PARMETIS_DIR}/build/lib/libparmetis:${HDF5_LIB_DIR}:\${LD_LIBRARY_PATH}"

# Full shared library (MFEM interface included)
export LIBROM_CFLAGS="-I${BUILD_DIR}/include"
export LIBROM_LDFLAGS="-Wl,-rpath,${BUILD_DIR}/lib -L${BUILD_DIR}/lib -lROM"

# PIC static core (no MFEM). The static library needs its whole dependency
# chain: ScaLAPACK, BLAS/LAPACK, parallel HDF5, zlib, gfortran runtime, and
# the Fortran bindings of MPI (libROM contains Fortran sources).
# HDF5 linkage state: ${HDF5_NOTE}
# NOTE: keep the HDF5 flags AFTER -lROM — when aligned, libsu2hdf5.a is a
# STATIC archive and must follow the objects that reference its symbols.
export LIBROM_STATIC_LDFLAGS="-L${BUILD_PIC_DIR}/lib -lROM -L${SCALAPACK_DIR} -lscalapack -llapack -lblas ${STATIC_HDF5_FLAGS} -lz -ldl -lm -lgfortran -lmpi_mpifh"
export LIBROM_HDF5_NOTE="${HDF5_NOTE}"

echo "libROM environment variables set (full shared + PIC static):"
echo "  LIBROM_DIR=\$LIBROM_DIR"
echo "  LIBROM_LIB_DIR=\$LIBROM_LIB_DIR  (shared, MFEM)"
echo "  LIBROM_INCLUDE_DIR=\$LIBROM_INCLUDE_DIR"
echo "  LIBROM_STATIC_LIB_DIR=\$LIBROM_STATIC_LIB_DIR  (PIC static core)"
echo "  LIBROM_CFLAGS=\$LIBROM_CFLAGS"
echo "  LIBROM_LDFLAGS=\$LIBROM_LDFLAGS"
echo "  LIBROM_STATIC_LDFLAGS=\$LIBROM_STATIC_LDFLAGS"
EOF

chmod +x "$ENV_FILE"
print_success "Environment setup script generated: ${ENV_FILE}"

# ============================================================================
# Step 10: Smoke test (both libraries)
# ============================================================================
print_info "Step 10: Smoke testing..."

source "$ENV_FILE" > /dev/null

TEST_SRC=$(mktemp /tmp/test_librom.XXXXXX.cpp)
cat > "$TEST_SRC" << 'EOF'
#include "librom.h"
#include "linalg/BasisGenerator.h"
#include "linalg/Matrix.h"
#include <mpi.h>
#include <cmath>
#include <iostream>

int main(int argc, char* argv[])
{
    MPI_Init(&argc, &argv);
    int rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    std::shared_ptr<const CAROM::Matrix> basis;
    {
        // Destroy the generator before MPI_Finalize: its destructor frees an
        // MPI communicator.
        CAROM::Options options(3, 5, false, false);
        CAROM::BasisGenerator gen(options, false /* static SVD */);
        for (int i = 0; i < 5; ++i) {
            double t = 0.25 * i;
            double u[3] = { std::sin(t), std::cos(t), std::sin(2.0 * t) };
            if (gen.isNextSample(t)) gen.takeSample(u);
        }
        gen.endSamples();
        basis = gen.getSpatialBasis();
    }
    bool ok = (basis->numRows() == 3) && (basis->numColumns() >= 1);
    if (rank == 0) {
        std::cout << "basis is " << basis->numRows() << " x "
                  << basis->numColumns() << ": "
                  << (ok ? "OK" : "FAILED") << std::endl;
    }
    MPI_Finalize();
    return ok ? 0 : 1;
}
EOF

TEST_OUT=$(mktemp /tmp/test_librom.XXXXXX.out)

if mpicxx -std=c++17 "$TEST_SRC" ${LIBROM_CFLAGS} ${LIBROM_LDFLAGS} -o "$TEST_OUT" && \
   "$TEST_OUT" > /dev/null; then
    print_success "Shared library smoke test passed"
else
    print_error "Shared library smoke test failed"
    rm -f "$TEST_SRC" "$TEST_OUT"
    exit 1
fi

if mpicxx -std=c++17 "$TEST_SRC" -I"${LIBROM_STATIC_INCLUDE_DIR}" ${LIBROM_STATIC_LDFLAGS} -o "$TEST_OUT" && \
   "$TEST_OUT" > /dev/null; then
    print_success "PIC static library smoke test passed"
else
    print_error "PIC static library smoke test failed"
    rm -f "$TEST_SRC" "$TEST_OUT"
    exit 1
fi

rm -f "$TEST_SRC" "$TEST_OUT"

echo ""
print_info "=========================================="
print_success "      libROM Installation Complete!"
print_info "=========================================="
echo ""
print_info "Installed features (full shared build, ${BUILD_DIR}):"
echo "  - SVD: static, incremental (standard/Brand), randomized"
echo "  - DMD family: DMD, DMDc, AdaptiveDMD, NonuniformDMD, SnapshotDMD, ParametricDMD"
echo "  - Hyper-reduction: DEIM, GNAT, QDEIM, S_OPT, STSampling"
echo "  - Greedy sampling: GreedySampler, GreedyCustomSampler, GreedyRandomSampler"
echo "  - Manifold interpolation: Interpolator, Matrix/Vector/PCHIP interpolators"
echo "  - MFEM interface: PointwiseSnapshot, SampleMesh, Utilities"
echo "  - Databases: HDF5 (parallel MPI-IO) and CSV"
echo "  - Examples, regression tests${ENABLE_TESTS:+ and unit tests (googletest)}"
echo ""
print_info "PIC static core build (for SU2, no MFEM): ${BUILD_PIC_DIR}"
echo ""
print_info "To use libROM:"
echo ""
echo "  source ${ENV_FILE}"
echo ""
echo "  # link against the full shared library:"
echo "  mpicxx -std=c++17 solver.cpp \${LIBROM_CFLAGS} \${LIBROM_LDFLAGS} -o solver.out"
echo ""
echo "  # or link the PIC static core (e.g. inside SU2 shared objects):"
echo "  mpicxx -std=c++17 solver.cpp -I\${LIBROM_STATIC_INCLUDE_DIR} \${LIBROM_STATIC_LDFLAGS} -o solver.out"
echo ""
print_info "Key headers:"
echo "  #include <librom.h>                     // 总头文件"
echo "  #include <linalg/BasisGenerator.h>      // 基函数生成"
echo "  #include <linalg/Matrix.h>              // 矩阵操作"
echo "  #include <linalg/Vector.h>              // 向量操作"
echo "  #include <algo/DMD.h>                   // 动态模态分解"
echo "  #include <hyperreduction/DEIM.h>        // DEIM 降阶"
echo "  #include <hyperreduction/GNAT.h>        // GNAT 超降阶"
echo ""
print_info "NOTE: libROM now requires C++17 (upstream commit #320)."
