#!/bin/bash
# Puts MapLibre's debug symbols into the archive.
#
# MapLibre arrives as a prebuilt binary through Swift Package Manager
# (maplibre-gl-native-distribution), and its xcframework ships no dSYM. Xcode
# cannot generate one for a binary it did not compile, so every archive
# uploads without symbols for MapLibre.framework and App Store Connect warns:
# "The archive did not include a dSYM for the MapLibre.framework with the
# UUIDs [...]". Crashes inside MapLibre then arrive unsymbolicated.
#
# MapLibre publishes the matching dSYM with each release. This phase runs on
# archive builds only, fetches that dSYM for the version pinned in
# project.yml (cached per version in the target's derived files), checks its UUIDs
# against the framework actually embedded in the archive, and copies it into
# the archive's dSYMs folder beside the app's own. A mismatch or a failed
# download is a warning, never a failed archive: the build is still valid,
# it just goes up unsymbolicated as it always did.
#
# Runs as a post-build phase of the MC1 target (see project.yml).
set -uo pipefail

# `xcodebuild archive` runs build phases with ACTION=install; anything else
# (build, test) has no archive to add to.
if [ "${ACTION:-build}" != "install" ]; then
  exit 0
fi

warn() { echo "warning: include-maplibre-dsym: $*"; }

VERSION=$(sed -n '/^  MapLibre:/,/^  [A-Za-z]/p' "${SRCROOT}/project.yml" | sed -n 's/^ *exactVersion: *//p' | head -1)
if [ -z "${VERSION}" ]; then
  warn "could not read MapLibre's exactVersion from project.yml; skipping"
  exit 0
fi

FRAMEWORK_BINARY="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/MapLibre.framework/MapLibre"
if [ ! -f "${FRAMEWORK_BINARY}" ]; then
  warn "MapLibre.framework not embedded at ${FRAMEWORK_BINARY}; skipping"
  exit 0
fi

# The phase is sandboxed (ENABLE_USER_SCRIPT_SANDBOXING), which refuses writes
# to ~/Library/Caches; the target's derived-file folder is its own to write.
# CI or a hand run outside Xcode has no DERIVED_FILE_DIR and keeps the old cache.
CACHE_ROOT="${DERIVED_FILE_DIR:-${HOME}/Library/Caches/DigitainoMesh}"
CACHE_DIR="${CACHE_ROOT}/MapLibre-dSYM/${VERSION}"
DSYM="${CACHE_DIR}/MapLibre.framework.dSYM"
# MAPLIBRE_DSYM_DIR lets a CI runner or a test point at a dSYM it already has.
if [ -n "${MAPLIBRE_DSYM_DIR:-}" ] && [ -d "${MAPLIBRE_DSYM_DIR}" ]; then
  DSYM="${MAPLIBRE_DSYM_DIR}"
elif [ ! -d "${DSYM}" ]; then
  URL="https://github.com/maplibre/maplibre-native/releases/download/ios-v${VERSION}/MapLibre_ios_device.framework.dSYM.zip"
  ZIP="${CACHE_DIR}/MapLibre_ios_device.framework.dSYM.zip"
  mkdir -p "${CACHE_DIR}"
  echo "include-maplibre-dsym: fetching ${URL}"
  if ! curl -fsSL --retry 2 -o "${ZIP}" "${URL}"; then
    warn "download failed (${URL}); the archive will go up without MapLibre symbols"
    rm -f "${ZIP}"
    exit 0
  fi
  UNPACK="${CACHE_DIR}/unpack"
  rm -rf "${UNPACK}" && mkdir -p "${UNPACK}"
  if ! ditto -x -k "${ZIP}" "${UNPACK}"; then
    warn "could not unzip ${ZIP}"
    rm -rf "${UNPACK}" "${ZIP}"
    exit 0
  fi
  FOUND=$(find "${UNPACK}" -maxdepth 3 -name "*.dSYM" -type d | head -1)
  if [ -z "${FOUND}" ]; then
    warn "no .dSYM inside ${ZIP}"
    rm -rf "${UNPACK}" "${ZIP}"
    exit 0
  fi
  # Named after the framework, as Xcode would have named its own.
  rm -rf "${DSYM}" && mv "${FOUND}" "${DSYM}"
  rm -rf "${UNPACK}" "${ZIP}"
fi

# The dSYM must describe the very binary in the archive: compare UUIDs.
binary_uuids=$(dwarfdump --uuid "${FRAMEWORK_BINARY}" 2>/dev/null | awk '{print $2}' | sort)
dsym_uuids=$(dwarfdump --uuid "${DSYM}" 2>/dev/null | awk '{print $2}' | sort)
if [ -z "${binary_uuids}" ] || [ -z "${dsym_uuids}" ]; then
  warn "could not read UUIDs (binary: '${binary_uuids}', dSYM: '${dsym_uuids}'); skipping"
  exit 0
fi
if [ -z "$(comm -12 <(echo "${binary_uuids}") <(echo "${dsym_uuids}"))" ]; then
  warn "dSYM UUIDs (${dsym_uuids}) do not match the embedded MapLibre (${binary_uuids}); skipping"
  exit 0
fi

DEST="${DWARF_DSYM_FOLDER_PATH}"
if [ -z "${DEST}" ]; then
  warn "DWARF_DSYM_FOLDER_PATH is empty; skipping"
  exit 0
fi
mkdir -p "${DEST}"
if rsync -a --delete "${DSYM}/" "${DEST}/MapLibre.framework.dSYM/"; then
  echo "include-maplibre-dsym: added MapLibre.framework.dSYM (${binary_uuids}) to ${DEST}"
else
  warn "could not copy the dSYM into ${DEST}"
fi
exit 0
