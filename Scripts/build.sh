#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_PATH="${REPO_ROOT}/QuickPreview.xcodeproj"
SCHEME="QuickPreview"
BUILD_ROOT="${REPO_ROOT}/build"
PRODUCTS_DIR="${BUILD_ROOT}/products"
ARCHIVES_DIR="${BUILD_ROOT}/archives"
PACKAGES_DIR="${BUILD_ROOT}/packages"
XCODE_ARCHIVES_DIR="${HOME}/Library/Developer/Xcode/Archives"

derived_data_path_for_configuration() {
  local configuration="$1"
  printf '%s\n' "${BUILD_ROOT}/DerivedData/${configuration}"
}

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/build.sh <command>
  ./Scripts/build.sh

Commands:
  debug             Build the direct-distribution Debug configuration.
  appstore          Build the App Store-safe Release configuration.
  pro               Build the direct-distribution Pro configuration.
  archive-appstore  Create a Release archive for App Store submission.
  archive-pro       Create a Pro archive for direct-distribution validation.
  package-pro       Build Pro and zip the app for website delivery.
  show-settings     Print the Xcode settings for a configuration.
  menu              Open the interactive build menu.
  clean             Remove the local build output folder.
  help              Show this help message.

Examples:
  ./Scripts/build.sh debug
  ./Scripts/build.sh appstore
  ./Scripts/build.sh archive-appstore
  ./Scripts/build.sh package-pro
  ./Scripts/build.sh
EOF
}

ensure_project() {
  if [[ ! -d "${PROJECT_PATH}" ]]; then
    echo "Could not find ${PROJECT_PATH}" >&2
    exit 1
  fi
}

ensure_directories() {
  mkdir -p "${PRODUCTS_DIR}" "${ARCHIVES_DIR}" "${PACKAGES_DIR}"
}

organizer_archive_path() {
  local archive_name="$1"
  local archive_day_dir="${XCODE_ARCHIVES_DIR}/$(date '+%Y-%m-%d')"
  local archive_timestamp="$(date '+%Y-%m-%d %H.%M')"
  mkdir -p "${archive_day_dir}"
  printf '%s\n' "${archive_day_dir}/${archive_name} ${archive_timestamp}.xcarchive"
}

run_xcodebuild() {
  local configuration="$1"
  shift

  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${configuration}" \
    -derivedDataPath "$(derived_data_path_for_configuration "${configuration}")" \
    "$@"
}

app_name_for_configuration() {
  local configuration="$1"

  case "${configuration}" in
    Debug|Pro)
      printf '%s\n' "QuickPreview Pro.app"
      ;;
    Release)
      printf '%s\n' "QuickPreview.app"
      ;;
    *)
      echo "Unknown configuration: ${configuration}" >&2
      exit 1
      ;;
  esac
}

build_configuration() {
  local configuration="$1"
  ensure_directories

  echo "Building ${configuration}..."
  run_xcodebuild "${configuration}" build

  local app_name
  app_name="$(app_name_for_configuration "${configuration}")"
  local app_path="$(derived_data_path_for_configuration "${configuration}")/Build/Products/${configuration}/${app_name}"
  echo "Built app: ${app_path}"
}

archive_configuration() {
  local configuration="$1"
  local archive_name="$2"
  ensure_directories

  local archive_path
  if [[ "${configuration}" == "Release" ]]; then
    archive_path="$(organizer_archive_path "${archive_name}")"
  else
    archive_path="${ARCHIVES_DIR}/${archive_name}.xcarchive"
  fi
  rm -rf "${archive_path}"

  echo "Archiving ${configuration} to ${archive_path}..."
  run_xcodebuild "${configuration}" \
    -archivePath "${archive_path}" \
    archive

  echo "Created archive: ${archive_path}"
  if [[ "${configuration}" == "Release" ]]; then
    echo
    echo "This App Store archive should now appear in Xcode Organizer."
    echo "Open Xcode > Window > Organizer, select the archive, then choose Distribute App."
  fi
}

package_pro() {
  ensure_directories
  build_configuration "Pro"

  local app_path="$(derived_data_path_for_configuration "Pro")/Build/Products/Pro/QuickPreview Pro.app"
  local zip_path="${PACKAGES_DIR}/QuickPreviewPro.zip"

  if [[ ! -d "${app_path}" ]]; then
    echo "Expected app not found at ${app_path}" >&2
    exit 1
  fi

  rm -f "${zip_path}"

  echo "Packaging ${app_path}..."
  ditto -c -k --sequesterRsrc --keepParent "${app_path}" "${zip_path}"
  echo "Created package: ${zip_path}"
}

show_settings() {
  local configuration="${1:-Release}"
  ensure_directories

  run_xcodebuild "${configuration}" -showBuildSettings
}

clean_build_outputs() {
  if [[ -d "${BUILD_ROOT}" ]]; then
    rm -rf "${BUILD_ROOT}"
    echo "Removed ${BUILD_ROOT}"
  else
    echo "Nothing to clean."
  fi
}

interactive_menu() {
  while true; do
    cat <<'EOF'

QuickPreview Build Menu
  1) Build Debug (direct-distribution dev build)
  2) Build App Store (Release)
  3) Build PRO
  4) Archive App Store submission build
  5) Archive PRO build
  6) Package PRO zip for website delivery
  7) Show App Store build settings
  8) Show PRO build settings
  9) Clean local build output
  0) Exit
EOF

    printf "Choose an option: "
    read -r choice

    case "${choice}" in
      1)
        build_configuration "Debug"
        ;;
      2)
        build_configuration "Release"
        ;;
      3)
        build_configuration "Pro"
        ;;
      4)
        archive_configuration "Release" "QuickPreview-AppStore"
        ;;
      5)
        archive_configuration "Pro" "QuickPreview-Pro"
        ;;
      6)
        package_pro
        ;;
      7)
        show_settings "Release"
        ;;
      8)
        show_settings "Pro"
        ;;
      9)
        clean_build_outputs
        ;;
      0|q|Q|quit|exit)
        echo "Done."
        break
        ;;
      *)
        echo "Unknown option: ${choice}" >&2
        ;;
    esac
  done
}

main() {
  ensure_project

  local command="${1:-menu}"

  case "${command}" in
    debug)
      build_configuration "Debug"
      ;;
    appstore)
      build_configuration "Release"
      ;;
    pro)
      build_configuration "Pro"
      ;;
    archive-appstore)
      archive_configuration "Release" "QuickPreview-AppStore"
      ;;
    archive-pro)
      archive_configuration "Pro" "QuickPreview-Pro"
      ;;
    package-pro)
      package_pro
      ;;
    show-settings)
      show_settings "${2:-Release}"
      ;;
    menu)
      interactive_menu
      ;;
    clean)
      clean_build_outputs
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Unknown command: ${command}" >&2
      echo >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
