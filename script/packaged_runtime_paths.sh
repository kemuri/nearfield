#!/usr/bin/env bash

# Sourced by the packager and exercised against real Mach-O binaries in tests.
runtime_rpaths() {
  otool -l "$1" |
    awk '$1 == "cmd" && $2 == "LC_RPATH" { wants_path = 1; next }
         wants_path && $1 == "path" {
           sub(/^[[:space:]]*path /, "")
           sub(/ \(offset [0-9]+\)$/, "")
           print
           wants_path = 0
         }'
}

validate_runtime_rpaths() {
  local binary="$1"
  local saw_framework_rpath=0
  local rpaths
  rpaths="$(runtime_rpaths "$binary")" || return 1
  local rpath
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    case "$rpath" in
      "/usr/lib/swift"|"@loader_path")
        ;;
      "@executable_path/../Frameworks")
        saw_framework_rpath=1
        ;;
      *)
        echo "unexpected runtime search path in packaged executable: $rpath" >&2
        return 1
        ;;
    esac
  done <<< "$rpaths"

  if [[ "$saw_framework_rpath" != "1" ]]; then
    echo "packaged executable is missing @executable_path/../Frameworks" >&2
    return 1
  fi
}

remove_build_toolchain_rpaths() {
  local binary="$1"
  local rpaths
  rpaths="$(runtime_rpaths "$binary")" || return 1
  local rpath
  while IFS= read -r rpath; do
    case "$rpath" in
      # Both Xcode and the separately mounted Metal toolchain inject these
      # build-machine paths. Distribution uses macOS's /usr/lib/swift instead.
      /*.xctoolchain/usr/lib/swift-*/macosx)
        install_name_tool -delete_rpath "$rpath" "$binary" || return 1
        ;;
    esac
  done <<< "$rpaths"
}
