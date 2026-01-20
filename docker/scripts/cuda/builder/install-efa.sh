#!/bin/bash
set -Eeu

# purpose: Install EFA
# -------------------------------
# Required docker secret mounts:
# - /run/secrets/subman_org: Subscription Manager Organization - used if on a ubi based image for entitlement
# - /run/secrets/subman_activation_key: Subscription Manager Activation key - used if on a ubi based image for entitlement
# -------------------------------
# Required environment variables:
# - TARGETOS: Target OS - either 'ubuntu' or 'rhel' (default: rhel)
# - EFA_PREFIX: Path to include ld linkers to ensure that UCX and NVSHMEM can build against EFA and Libfacbric successfully
# - EFA_INSTALLER_VERSION: Version of AWS EFA installer to download (default: 1.46.0 is the current latest release)

if [ "$TARGETOS" = "ubuntu" ]; then
    echo "Ubuntu image needs to be built against Ubuntu 20.04 and EFA only supports 22.04 and 24.04."
    mkdir -p "${EFA_PREFIX}"
    exit 0
fi

TARGETOS="${TARGETOS:-rhel}"
EFA_INSTALLER_VERSION="${EFA_INSTALLER_VERSION:-1.46.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# source shared utilities (check script dir first, fallback to /tmp for docker builds)
UTILS_SCRIPT="${SCRIPT_DIR}/../common/package-utils.sh"
[ ! -f "$UTILS_SCRIPT" ] && UTILS_SCRIPT="/tmp/package-utils.sh"
if [ ! -f "$UTILS_SCRIPT" ]; then
    echo "ERROR: package-utils.sh not found" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$UTILS_SCRIPT"

if [ "$TARGETOS" = "ubuntu" ]; then
    # efa uses apt instead of apt-get
    apt update -y
fi

EFA_INSTALLER_URL="https://efa-installer.amazonaws.com"
EFA_TARBALL="aws-efa-installer-${EFA_INSTALLER_VERSION}.tar.gz"
EFA_WORKDIR="/tmp/efa"

echo "Installing AWS EFA (Elastic Fabric Adapter) ${EFA_INSTALLER_VERSION}"

mkdir -p "${EFA_WORKDIR}" /etc/ld.so.conf.d/
curl -fsSL "${EFA_INSTALLER_URL}/${EFA_TARBALL}" -o "${EFA_WORKDIR}/${EFA_TARBALL}"
tar -xzf "${EFA_WORKDIR}/${EFA_TARBALL}" -C "${EFA_WORKDIR}"

cd "${EFA_WORKDIR}/aws-efa-installer" && ./efa_installer.sh --skip-kmod --no-verify -y

ldconfig
rm -rf "${EFA_WORKDIR}"

# new EFA installer puts libefa.so.1 in different locations depending on OS:
# - RHEL/UBI: /usr/lib64
# - Ubuntu: /usr/lib/x86_64-linux-gnu or /usr/lib/aarch64-linux-gnu
mkdir -p /tmp/efa_libs
if [ "$TARGETOS" = "ubuntu" ]; then
    if [ "${TARGETPLATFORM:-linux/amd64}" = "linux/arm64" ]; then
        if [ -f /usr/lib/aarch64-linux-gnu/libefa.so.1 ]; then
            cp -a /usr/lib/aarch64-linux-gnu/libefa.so* /tmp/efa_libs/ || true
        fi
    else
        if [ -f /usr/lib/x86_64-linux-gnu/libefa.so.1 ]; then
            cp -a /usr/lib/x86_64-linux-gnu/libefa.so* /tmp/efa_libs/ || true
        fi
    fi
    cleanup_packages ubuntu
elif [ "$TARGETOS" = "rhel" ]; then
    if [ -f /lib64/libefa.so.1 ]; then
        cp -a /lib64/libefa.so* /tmp/efa_libs/ || true
    fi
    cleanup_packages rhel
    ensure_unregistered
else
    echo "ERROR: Unsupported TARGETOS='$TARGETOS'. Must be 'ubuntu' or 'rhel'." >&2
    exit 1
fi
