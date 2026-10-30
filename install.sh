#!/bin/bash

# FIND: v0.4.2
TAG=0.4.2
if [[ "$@" != "" ]]
then
  TAG="$@"
fi

# GitHub repository that hosts the release bundles. Override with CYBER_REPO.
CYBER_REPO="${CYBER_REPO:-soomtong/cyber}"
CYBER_RELEASES="https://github.com/${CYBER_REPO}/releases/download/${TAG}"

abort() {
  printf "%s\n" "$@" >&2
  exit 1
}

# First check OS.
OS="$(uname)"
if [[ "${OS}" == "Linux" ]]
then
  CYBER_LINUX=1
elif [[ "${OS}" == "Darwin" ]]
then
  CYBER_MACOS=1
else
  abort "Install is only supported on macOS and Linux."
fi

# Pick the bundle for this machine.
if [[ -n "${CYBER_MACOS}" ]]
then
  UNAME_MACHINE="$(/usr/bin/uname -m)"
  if [[ "${UNAME_MACHINE}" == "arm64" ]]
  then
    CYBER_BUNDLE="${CYBER_RELEASES}/cyber-macos-arm64.tar.gz"
  else
    CYBER_BUNDLE="${CYBER_RELEASES}/cyber-macos-x64.tar.gz"
  fi
else
  CYBER_BUNDLE="${CYBER_RELEASES}/cyber-linux-x64.tar.gz"
fi

# The bundle holds the executable and its standard modules (`src/`), which the
# executable looks up next to itself. Keep them together under CYBER_HOME and
# link the binary into CYBER_BIN, which should be on PATH.
CYBER_HOME="${CYBER_HOME:-/usr/local/lib/cyber}"
CYBER_BIN="${CYBER_BIN:-/usr/local/bin}"

# Use sudo only when the destination is not writable by the current user.
# Set CYBER_SUDO=0 to never use sudo, or CYBER_SUDO=1 to always use it.
first_existing_parent() {
  local dir="$1"
  while [[ ! -d "${dir}" && "${dir}" != "/" ]]
  do
    dir="$(dirname "${dir}")"
  done
  printf "%s" "${dir}"
}

if [[ -z "${CYBER_SUDO}" ]]
then
  CYBER_SUDO=0
  for dir in "${CYBER_HOME}" "${CYBER_BIN}"
  do
    if [[ ! -w "$(first_existing_parent "${dir}")" ]]
    then
      CYBER_SUDO=1
    fi
  done
fi

if [[ "${CYBER_SUDO}" == "1" ]]
then
  if [[ "$(id -u)" == "0" ]]
  then
    SUDO=""
  else
    SUDO="sudo"
  fi
else
  SUDO=""
fi

echo "Downloading ${CYBER_BUNDLE}."
${SUDO} sh -c "mkdir -p '${CYBER_HOME}' '${CYBER_BIN}' && \
    curl -fsSL '${CYBER_BUNDLE}' | tar -xz -C '${CYBER_HOME}' && \
    chmod a+x '${CYBER_HOME}/cyber' && \
    ln -sf '${CYBER_HOME}/cyber' '${CYBER_BIN}/cyber'" \
  || abort "Install failed."
echo "Installed to ${CYBER_HOME}, linked as ${CYBER_BIN}/cyber."
