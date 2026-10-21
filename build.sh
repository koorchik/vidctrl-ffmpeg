#!/usr/bin/env bash
# Builds the FFmpeg that VidCtrl ships: static ffmpeg and ffprobe with only
# the libraries VidCtrl uses. GPL v3, nothing nonfree.
#
#   ./build.sh macos     on a Mac: Apple Silicon and Intel, joined into
#                        universal binaries
#   ./build.sh linux     on Ubuntu 24.04, for Linux x86-64
#   ./build.sh windows   on Ubuntu 24.04, for Windows x64 (cross-compiled)
#
# Leaves in dist/:
#   ffmpeg-<version>-<system>.zip       ffmpeg, ffprobe, BUILDINFO.txt
#   ffmpeg-<version>-sources.tar        every source tarball and this script
#
# Needs, on a Mac, Xcode's command line tools and, from Homebrew:
#   brew install cmake meson ninja nasm pkgconf autoconf automake libtool
# on Ubuntu 24.04:
#   apt-get install build-essential cmake meson ninja-build nasm pkg-config \
#     autoconf automake libtool curl ca-certificates xz-utils bzip2 zip xxd
# and for Windows also:
#   apt-get install gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix
#
# Every source is pinned by checksum. To move a library to a newer version,
# change its line in `sources` and build again; check.sh tells whether the
# result is right.
set -euo pipefail
# macOS's own bash is 3.2: an empty array counts as unset under `set -u`,
# hence the ${array[@]+"${array[@]}"} below.

# The release this script makes: FFmpeg's version and this build's number.
version=8.1.3-3

# VidCtrl's own minimum (macos/Runner.xcodeproj in VidCtrl).
min_macos=12.0

# name | file | url | sha256
sources=(
  "ffmpeg|ffmpeg-8.1.3.tar.xz|https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz|7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"
  "svt-av1|SVT-AV1-v4.2.0.tar.gz|https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v4.2.0/SVT-AV1-v4.2.0.tar.gz|c7b13c4a84bd3751aa35fcc72be13e6875467e7c2216879251a486e5b1e4e740"
  "x265|x265_4.3.tar.gz|https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz|83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121"
  "x264|x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2|https://code.videolan.org/videolan/x264/-/archive/b35605ace3ddf7c1a5d67a2eb553f034aef41d55/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2|6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"
  "dav1d|dav1d-1.5.4.tar.xz|https://downloads.videolan.org/pub/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz|686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
  "zimg|zimg-release-3.0.6.tar.gz|https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz|be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577"
  "vmaf|vmaf-3.2.1.tar.gz|https://github.com/Netflix/vmaf/archive/refs/tags/v3.2.1.tar.gz|5df7386911bc15fd1ca783132528748d219768ae4fc5f8e0b61184f041648092"
  "lame|lame-3.100.tar.gz|https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz|ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
  # Linux and Windows only; macOS has its own zlib and hardware encoders.
  "zlib|zlib-1.3.2.tar.xz|https://github.com/madler/zlib/releases/download/v1.3.2/zlib-1.3.2.tar.xz|d7a0654783a4da529d1bb793b7ad9c3318020af77667bcae35f95d0e42a792f3"
  # NVIDIA's encoders: headers only, the driver is loaded when used. 12.1
  # has AV1 and asks for the oldest driver that does (530 on Linux, 531.61
  # on Windows).
  "nv-codec-headers|nv-codec-headers-12.1.14.1.tar.gz|https://github.com/FFmpeg/nv-codec-headers/releases/download/n12.1.14.1/nv-codec-headers-12.1.14.1.tar.gz|043e46265517855f13bcb98b3a225b2761b2a83983b1645fa1d05876f1c3a781"
  # Windows only: AMD's encoders (headers only; the oldest FFmpeg 8.1 takes,
  # for the oldest driver) and Intel's (the loader of its runtime).
  "amf|AMF-headers-v1.4.36.tar.gz|https://github.com/GPUOpen-LibrariesAndSDKs/AMF/releases/download/v1.4.36/AMF-headers-v1.4.36.tar.gz|ec07ee21b820a73f5bae224e92fd3c492f52732d4885f0637f48189afdd87564"
  "libvpl|libvpl-2.16.0.tar.gz|https://github.com/intel/libvpl/archive/refs/tags/v2.16.0.tar.gz|d60931937426130ddad9f1975c010543f0da99e67edb1c6070656b7947f633b6"
)

target="${1:-}"
case "$target" in
  macos) archs=(arm64 x86_64) system=macos ;;
  linux) archs=(x86_64) system=linux-x64 ;;
  windows) archs=(x86_64) system=windows-x64 ;;
  *)
    echo "usage: $0 macos|linux|windows" >&2
    exit 64
    ;;
esac

root="$(cd "$(dirname "$0")" && pwd)"
work="${WORK:-$root/work}"
dist="$root/dist"
if [[ "$(uname -s)" == Darwin ]]; then
  jobs="$(sysctl -n hw.ncpu)"
else
  jobs="$(nproc)"
fi
mkdir -p "$work/downloads" "$dist"

log() { printf '\n== %s\n' "$*"; }

sha256() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Every source, fetched once and checked.
fetch_all() {
  local entry n file url sum
  for entry in "${sources[@]}"; do
    IFS='|' read -r n file url sum <<< "$entry"
    if [[ ! -f "$work/downloads/$file" ]]; then
      curl -fsSL --retry 3 -o "$work/downloads/$file.tmp" "$url"
      mv "$work/downloads/$file.tmp" "$work/downloads/$file"
    fi
    if [[ "$(sha256 "$work/downloads/$file")" != "$sum" ]]; then
      echo "checksum mismatch: $file" >&2
      exit 1
    fi
  done
}

# The unpacked source of [name], for the build in $build_dir.
source_dir() {
  local name="$1" entry n file url sum dir
  for entry in "${sources[@]}"; do
    IFS='|' read -r n file url sum <<< "$entry"
    [[ "$n" == "$name" ]] || continue
    dir="$build_dir/src/$name"
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      tar -xf "$work/downloads/$file" -C "$dir" --strip-components 1
    fi
    echo "$dir"
    return
  done
  echo "no source named $name" >&2
  exit 1
}

# Compilers and flags for $arch of $target, and the descriptions CMake and
# Meson need when the build is for another computer than this one.
toolchain() {
  prefix="$build_dir/prefix"
  mkdir -p "$prefix/lib/pkgconfig" "$prefix/include"
  # Only the libraries built here; nothing installed on the computer is
  # linked in.
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  unset PKG_CONFIG_PATH
  cmake_args=(
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DBUILD_SHARED_LIBS=OFF
  )
  meson_cross=()
  # Meson's name of the other system, empty when building for this one.
  cross_system=""
  local native cpu_family=x86_64
  case "$target" in
    macos)
      native="$(uname -m)"
      host="$([[ "$arch" == arm64 ]] && echo aarch64 || echo x86_64)-apple-darwin"
      build="$([[ "$native" == arm64 ]] && echo aarch64 || echo x86_64)-apple-darwin"
      [[ "$arch" == arm64 ]] && cpu_family=aarch64
      flags="-arch $arch -mmacosx-version-min=$min_macos"
      export MACOSX_DEPLOYMENT_TARGET="$min_macos"
      export CC=clang CXX=clang++ AR=ar
      cross_prefix=""
      cmake_args+=(
        -DCMAKE_OSX_ARCHITECTURES="$arch"
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_macos"
      )
      if [[ "$arch" != "$native" ]]; then
        cmake_args+=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$arch")
        cross_system=darwin
      fi
      ;;
    linux)
      host=x86_64-linux-gnu
      build="$host"
      # Ubuntu links programs position-independent.
      flags="-fPIC"
      export CC=gcc CXX=g++ AR=ar
      cross_prefix=""
      cmake_args+=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
      ;;
    windows)
      host=x86_64-w64-mingw32
      build=x86_64-linux-gnu
      flags=""
      cross_prefix="$host-"
      # The compilers with POSIX threads, which C++ threads need.
      export CC="$host-gcc-posix" CXX="$host-g++-posix" AR="$host-ar"
      cmake_args+=(
        -DCMAKE_SYSTEM_NAME=Windows
        -DCMAKE_SYSTEM_PROCESSOR=x86_64
        -DCMAKE_C_COMPILER="$CC"
        -DCMAKE_CXX_COMPILER="$CXX"
        -DCMAKE_RC_COMPILER="$host-windres"
        -DCMAKE_FIND_ROOT_PATH="$prefix"
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
      )
      cross_system=windows
      ;;
  esac
  link_flags="${flags/-fPIC/}"
  export CFLAGS="$flags -O2" CXXFLAGS="$flags -O2" LDFLAGS="$link_flags"
  [[ -n "$cross_system" ]] || return 0
  local c cpp ar strip extra
  if [[ "$target" == macos ]]; then
    c="'clang', '-arch', '$arch'" cpp="'clang++', '-arch', '$arch'"
    ar="'ar'" strip="'strip'"
    extra="
[built-in options]
c_args = ['-mmacosx-version-min=$min_macos']
c_link_args = ['-mmacosx-version-min=$min_macos']
cpp_args = ['-mmacosx-version-min=$min_macos']
cpp_link_args = ['-mmacosx-version-min=$min_macos']"
  else
    c="'$CC'" cpp="'$CXX'" ar="'$AR'" strip="'$host-strip'"
    extra="windres = '$host-windres'"
  fi
  cat > "$build_dir/meson-cross.txt" <<EOF
[binaries]
c = [$c]
cpp = [$cpp]
ar = $ar
strip = $strip
nasm = 'nasm'
pkg-config = 'pkg-config'
$extra

[host_machine]
system = '$cross_system'
cpu_family = '$cpu_family'
cpu = '$arch'
endian = 'little'
EOF
  meson_cross=(--cross-file "$build_dir/meson-cross.txt")
}

# Joins static libraries into one.
join_static() {
  local out="$1" lib
  shift
  if [[ "$target" == macos ]]; then
    libtool -static -o "$out" "$@"
  else
    {
      echo "CREATE $out"
      for lib in "$@"; do echo "ADDLIB $lib"; done
      echo "SAVE"
      echo "END"
    } | "$AR" -M
  fi
}

build_arch() {
  arch="$1"
  build_dir="$work/$target-$arch"
  toolchain
  local src

  log "$arch: lame"
  src="$(source_dir lame)"
  (cd "$src" &&
    ac_cv_prog_cc_c23=no CFLAGS="$CFLAGS -Wno-implicit-function-declaration" \
      ./configure --prefix="$prefix" --build="$build" --host="$host" \
      --enable-static --disable-shared --disable-frontend \
      --disable-dependency-tracking &&
    make -j"$jobs" install)

  log "$arch: zimg"
  src="$(source_dir zimg)"
  (cd "$src" &&
    LIBTOOLIZE="$(command -v glibtoolize || echo libtoolize)" ./autogen.sh &&
    ./configure --prefix="$prefix" --build="$build" --host="$host" \
      --enable-static --disable-shared &&
    make -j"$jobs" install)

  log "$arch: x264"
  src="$(source_dir x264)"
  (cd "$src" &&
    ./configure --prefix="$prefix" --host="$host" \
      ${cross_prefix:+--cross-prefix="$cross_prefix"} \
      --enable-static --enable-pic --disable-cli \
      --disable-lsmash --disable-swscale --disable-ffms \
      --extra-cflags="$flags" --extra-ldflags="$link_flags" &&
    make -j"$jobs" install-lib-static)

  log "$arch: x265 (8, 10 and 12 bit in one library)"
  src="$(source_dir x265)"
  local x265="$build_dir/x265"
  local common=(-DENABLE_SHARED=OFF -DENABLE_CLI=OFF)
  [[ "$target" == linux ]] && common+=(-DENABLE_PIC=ON)
  local high=(-DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF "${common[@]}")
  mkdir -p "$x265/8bit"
  cmake -S "$src/source" -B "$x265/10bit" "${cmake_args[@]}" "${high[@]}" -DENABLE_HDR10_PLUS=ON
  make -C "$x265/10bit" -j"$jobs"
  cp "$x265/10bit/libx265.a" "$x265/8bit/libx265_main10.a"
  cmake -S "$src/source" -B "$x265/12bit" "${cmake_args[@]}" "${high[@]}" -DMAIN12=ON
  make -C "$x265/12bit" -j"$jobs"
  cp "$x265/12bit/libx265.a" "$x265/8bit/libx265_main12.a"
  cmake -S "$src/source" -B "$x265/8bit" "${cmake_args[@]}" "${common[@]}" \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
    -DEXTRA_LINK_FLAGS=-L. "-DEXTRA_LIB=x265_main10.a;x265_main12.a"
  make -C "$x265/8bit" -j"$jobs"
  (cd "$x265/8bit" && mv libx265.a libx265_main.a &&
    join_static libx265.a libx265_main.a libx265_main10.a libx265_main12.a &&
    make install)

  log "$arch: SVT-AV1"
  src="$(source_dir svt-av1)"
  cmake -S "$src" -B "$build_dir/svt-av1" -G Ninja "${cmake_args[@]}" \
    -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
  ninja -C "$build_dir/svt-av1" install

  log "$arch: dav1d"
  src="$(source_dir dav1d)"
  meson setup "$build_dir/dav1d" "$src" ${meson_cross[@]+"${meson_cross[@]}"} \
    --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$build_dir/dav1d" install

  log "$arch: libvmaf"
  src="$(source_dir vmaf)"
  meson setup "$build_dir/vmaf" "$src/libvmaf" ${meson_cross[@]+"${meson_cross[@]}"} \
    --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tests=false -Denable_docs=false \
    -Denable_tools=false -Dbuilt_in_models=true -Denable_float=true
  ninja -C "$build_dir/vmaf" install

  if [[ "$target" != macos ]]; then
    log "$arch: zlib"
    src="$(source_dir zlib)"
    (cd "$src" &&
      CHOST="${cross_prefix%-}" ./configure --prefix="$prefix" --static &&
      make -j"$jobs" install)

    log "$arch: NVIDIA's encoder headers"
    src="$(source_dir nv-codec-headers)"
    make -C "$src" PREFIX="$prefix" install
  fi

  if [[ "$target" == windows ]]; then
    log "$arch: AMD's encoder headers"
    src="$(source_dir amf)"
    rm -rf "$prefix/include/AMF"
    cp -R "$src/AMF" "$prefix/include/AMF"

    log "$arch: Intel's VPL loader"
    src="$(source_dir libvpl)"
    cmake -S "$src" -B "$build_dir/libvpl" -G Ninja "${cmake_args[@]}" \
      -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DINSTALL_EXAMPLES=OFF \
      -DBUILD_TESTS=OFF
    ninja -C "$build_dir/libvpl" install
  fi

  # FFmpeg links with the C++ compiler, which brings the C++ runtime in the
  # way each system needs (below); the libraries' own descriptions would
  # link its shared parts.
  if [[ "$target" != macos ]]; then
    sed -i -E 's/-l(stdc\+\+|gcc_s|gcc|c\+\+)([[:space:]]|$)/\2/g' \
      "$prefix"/lib/pkgconfig/*.pc
  fi

  log "$arch: FFmpeg"
  src="$(source_dir ffmpeg)"
  local options=() extra_libs ldflags="$link_flags"
  case "$target" in
    macos)
      if [[ -n "$cross_system" ]]; then
        options=(--enable-cross-compile --arch="$arch" --target-os=darwin)
      fi
      options+=(
        --enable-pthreads
        --enable-videotoolbox --enable-audiotoolbox
        --enable-zlib --enable-bzlib --enable-iconv
      )
      extra_libs="-lc++ -liconv"
      ;;
    linux)
      options=(
        --enable-pic --enable-pthreads --enable-iconv --enable-zlib
        --enable-ffnvcodec --enable-nvenc
      )
      # Static but for the C library, through which NVIDIA's driver is
      # loaded.
      ldflags+=" -static-libgcc -static-libstdc++"
      # configure tries the C++ libraries with the C compiler, which needs
      # the C++ runtime named; the final link leaves the name out.
      extra_libs="-lstdc++ -lm -lpthread -ldl"
      ;;
    windows)
      options=(
        --enable-cross-compile --arch=x86_64 --target-os=mingw32
        --cross-prefix="$cross_prefix" --pkg-config=pkg-config
        --enable-w32threads --enable-zlib
        --enable-d3d11va --enable-dxva2
        --enable-ffnvcodec --enable-nvenc --enable-amf --enable-libvpl
        # A screen grabber VidCtrl does not use, which needs newer AMF
        # headers, and so newer drivers, than the encoders do.
        --disable-filter=amf_capture
        # Old webcam capture, the only part that needs a DLL beyond the
        # core of Windows.
        --disable-indev=vfwcap
      )
      ldflags+=" -static"
      extra_libs="-lstdc++ -lpthread"
      ;;
  esac
  mkdir -p "$build_dir/ffmpeg"
  (cd "$build_dir/ffmpeg" &&
    "$src/configure" --prefix="$prefix" \
      --cc="$CC" --cxx="$CXX" \
      --extra-cflags="$flags -I$prefix/include" \
      --extra-ldflags="$ldflags -L$prefix/lib" \
      --extra-libs="$extra_libs" \
      --pkg-config-flags=--static \
      --extra-version=vidctrl \
      --enable-gpl --enable-version3 \
      --disable-autodetect \
      "${options[@]}" \
      --enable-libsvtav1 --enable-libx265 --enable-libx264 \
      --enable-libdav1d --enable-libmp3lame --enable-libzimg --enable-libvmaf \
      --disable-ffplay --disable-doc --disable-debug \
      --enable-static --disable-shared &&
    make -j"$jobs" &&
    make install)
}

fetch_all
for arch in "${archs[@]}"; do
  build_arch "$arch"
done

out="$work/$target"
rm -rf "$out"
mkdir -p "$out"
case "$target" in
  macos)
    log "universal binaries"
    for tool in ffmpeg ffprobe; do
      lipo -create "$work/macos-arm64/prefix/bin/$tool" \
        "$work/macos-x86_64/prefix/bin/$tool" -output "$out/$tool"
    done
    description="macOS (Apple Silicon and Intel, macOS $min_macos or newer)"
    ;;
  linux)
    for tool in ffmpeg ffprobe; do
      strip -o "$out/$tool" "$work/linux-x86_64/prefix/bin/$tool"
    done
    description="Linux x86-64"
    ;;
  windows)
    for tool in ffmpeg ffprobe; do
      x86_64-w64-mingw32-strip -o "$out/$tool.exe" \
        "$work/windows-x86_64/prefix/bin/$tool.exe"
    done
    description="Windows x64"
    ;;
esac

{
  echo "FFmpeg $version for $description, built by build.sh."
  echo
  echo "Sources:"
  for entry in "${sources[@]}"; do
    IFS='|' read -r n file url sum <<< "$entry"
    [[ -d "$work/$target-${archs[0]}/src/$n" ]] || continue
    echo "  $file  sha256 $sum"
    echo "    $url"
  done
  echo
  echo "Configuration:"
  sed -n 's/^#define FFMPEG_CONFIGURATION "\(.*\)"$/\1/p' \
    "$work/$target-${archs[0]}/ffmpeg/config.h" | tr ' ' '\n' | sed 's/^/  /'
} > "$out/BUILDINFO.txt"

zip_name="ffmpeg-$version-$system.zip"
rm -f "$dist/$zip_name"
(cd "$out" && zip -q -X "$dist/$zip_name" *)
tar_name="ffmpeg-$version-sources.tar"
(cd "$work/downloads" && cp "$root/build.sh" . &&
  tar -cf "$dist/$tar_name" build.sh \
    $(for entry in "${sources[@]}"; do IFS='|' read -r n file url sum <<< "$entry"; echo "$file"; done))
for file in "$dist/$zip_name" "$dist/$tar_name"; do
  echo "$(sha256 "$file")  $(basename "$file")"
done
