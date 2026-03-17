#!/bin/bash
set -Eeu

# builds and installs LMCache and Infinistore from source
#
# Required environment variables:
# - USE_SCCACHE: whether to use sccache (true/false)
# - VIRTUAL_ENV: path to Python virtual environment
# - INFINISTORE_REPO: git repo to build Infinistore from
# - INFINISTORE_VERSION: git ref to build Infinistore from
# - LMCACHE_REPO: git repo to build LMCache from
# - LMCACHE_VERSION: git ref to build LMCache from
# Optional environment variables:
# - TARGETPLATFORM: platform target (linux/arm64 or linux/amd64)
# - TARGETOS: OS type (ubuntu or rhel)

cd /tmp

. /usr/local/bin/setup-sccache
. "${VIRTUAL_ENV}/bin/activate"

# PyTorch cpp_extension doesn't recognize "10.0f" syntax, normalize to standard format
export TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST//10.0f/10.0}"

# Note: We intentionally do NOT set CC="sccache gcc" here because
# torch's cpp_extension passes CC/CXX to nvcc -ccbin which doesn't
# understand space-separated wrapper commands like "sccache gcc".
# sccache for these builds would require NVCC_CCBIN_FLAGS or similar.

git clone "${INFINISTORE_REPO}" infinistore && cd infinistore
git checkout -q "${INFINISTORE_VERSION}"
uv build --wheel --no-build-isolation --out-dir /wheels
cd ..
rm -rf infinistore

git clone "${LMCACHE_REPO}" lmcache && cd lmcache
git checkout -q "${LMCACHE_VERSION}"
uv build --wheel --no-build-isolation --out-dir /wheels  && \
cd ..
rm -rf lmcache

if [ "${USE_SCCACHE}" = "true" ]; then
    echo "=== LMCache and Infinistore build complete - sccache stats ==="
    sccache --show-stats
fi
