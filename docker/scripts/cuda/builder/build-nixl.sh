#!/bin/bash
set -Eeu

# purpose: builds NIXL from source, gated by `BUILD_NIXL_FROM_SOURCE`
#
# Required environment variables:
# - BUILD_NIXL_FROM_SOURCE: if nixl should be installed by vLLM or has been built from source in the builder stages
# - NIXL_REPO: Git repo to use for NIXL
# - NIXL_VERSION: Git ref to use for NIXL
# - NIXL_PREFIX: Path to install NIXL to
# - EFA_PREFIX: Path to Libfabric installation
# - UCX_PREFIX: Path to UCX installation
# - VIRTUAL_ENV: Path to the virtual environment
# - USE_SCCACHE: whether to use sccache (true/false)
# - TARGETOS: OS type (ubuntu or rhel)

if [ "${BUILD_NIXL_FROM_SOURCE}" = "false" ]; then
    echo "NIXL will be installed be vLLM and not built from source."
    exit 0
fi

cd /tmp

. /usr/local/bin/setup-sccache
. "${VIRTUAL_ENV}/bin/activate"

# Meson 1.3.0+ reads CMAKE_*_COMPILER_LAUNCHER env vars directly.
# Ensure they're unset if sccache isn't ready.
echo "DEBUG: SCCACHE_READY=${SCCACHE_READY:-unset}"
echo "DEBUG: CMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER:-unset}"
if [ "${SCCACHE_READY:-false}" != "true" ]; then
    unset CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER CMAKE_CUDA_COMPILER_LAUNCHER
    echo "DEBUG: after unset CMAKE_CXX_COMPILER_LAUNCHER=${CMAKE_CXX_COMPILER_LAUNCHER:-unset}"
else
    export CC="sccache gcc" CXX="sccache g++" NVCC="sccache nvcc"
fi

git clone "${NIXL_REPO}" nixl && cd nixl
git checkout -q "${NIXL_VERSION}"

# Ubuntu image needs to be built against Ubuntu 20.04 and EFA only supports 22.04 and 24.04.
EFA_FLAG=""
if [ "$TARGETOS" = "rhel" ]; then
    EFA_FLAG="-Dlibfabric_path=${EFA_PREFIX}"
fi

meson setup build \
    --prefix="${NIXL_PREFIX}" \
    -Dbuildtype=release \
    -Ducx_path="${UCX_PREFIX}" \
    ${EFA_FLAG:+"$EFA_FLAG"} \
    -Dinstall_headers=true

cd build
ninja
ninja install
cd ..
. ${VIRTUAL_ENV}/bin/activate
python -m build --no-isolation --wheel -o /wheels

cp build/src/bindings/python/nixl-meta/nixl-*-py3-none-any.whl /wheels/

rm -rf build

cd /tmp && rm -rf /tmp/nixl 

