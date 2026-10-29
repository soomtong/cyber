#!/bin/bash

# FIND: v0.4.1
TAG=0.4.1
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
  CYBER_PATH=/usr/local/bin
elif [[ "${OS}" == "Darwin" ]]
then
  CYBER_MACOS=1
  CYBER_PATH=/usr/local/bin
else
  abort "Install is only supported on macOS and Linux."
fi

# Required installation paths.
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
  UNAME_MACHINE="$(uname -m)"
  CYBER_BUNDLE="${CYBER_RELEASES}/cyber-linux-x64.tar.gz"
fi

# The bundle holds the executable and its standard modules (`src/`), which the
# executable looks up next to itself. Keep them together and link the binary into PATH.
CYBER_HOME="${CYBER_HOME:-/usr/local/lib/cyber}"

sudo sh -c "mkdir -p ${CYBER_HOME} ${CYBER_PATH}; \
    echo 'Downloading ${CYBER_BUNDLE}.'; \
    curl -fsSL $CYBER_BUNDLE | tar -xz -C $CYBER_HOME; \
    chmod a+x ${CYBER_HOME}/cyber; \
    ln -sf ${CYBER_HOME}/cyber ${CYBER_PATH}/cyber; \
    echo 'Installed to ${CYBER_HOME}, linked as ${CYBER_PATH}/cyber.'"
