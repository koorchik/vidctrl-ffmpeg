#!/usr/bin/env bash
# Builds the FFmpeg that VidCtrl ships on macOS: static ffmpeg and ffprobe for
# Apple Silicon and Intel, joined into universal binaries, with only the
# libraries VidCtrl uses. GPL v3, nothing nonfree.
#
#   ./build.sh
#
# Leaves in dist/:
#   ffmpeg-<version>-macos.zip           ffmpeg, ffprobe, BUILDINFO.txt
#   ffmpeg-<version>-macos-sources.tar   every source tarball and this script
#
# Needs Xcode's command line tools and, from Homebrew:
#   brew install cmake meson ninja nasm pkgconf autoconf automake libtool
#
# Every source is pinned by checksum. To move a library to a newer version,
# change its line in `sources` and build again; check.sh tells whether the
# result is right.
set -euo pipefail
# macOS's own bash is 3.2: an empty array counts as unset under `set -u`,
# hence the ${array[@]+"${array[@]}"} below.

# The release this script makes: FFmpeg's version and this build's number.
version=8.1.3-1

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
  "lame|lame-3.100.tar.gz|https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz|ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
)

root="$(cd "$(dirname "$0")" && pwd)"
work="${WORK:-$root/work}"
dist="$root/dist"
jobs="$(sysctl -n hw.ncpu)"
mkdir -p "$work/downloads" "$dist"

log() { printf '\n== %s\n' "$*"; }

# The unpacked source of [name], fetched and checked once.
source_dir() {
  local name="$1" entry file url sum dir
  for entry in "${sources[@]}"; do
    IFS='|' read -r n file url sum <<< "$entry"
    [[ "$n" == "$name" ]] || continue
    if [[ ! -f "$work/downloads/$file" ]]; then
      curl -fsSL --retry 3 -o "$work/downloads/$file.tmp" "$url"
      mv "$work/downloads/$file.tmp" "$work/downloads/$file"
    fi
    if [[ "$(shasum -a 256 "$work/downloads/$file" | cut -d' ' -f1)" != "$sum" ]]; then
      echo "checksum mismatch: $file" >&2
      exit 1
    fi
    dir="$work/$arch/src/$name"
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

build_arch() {
  arch="$1"
  local prefix="$work/$arch/prefix" host cmake_cross=() native
  native="$(uname -m)"
  case "$arch" in
    arm64) host=aarch64-apple-darwin ;;
    x86_64) host=x86_64-apple-darwin ;;
  esac
  if [[ "$arch" != "$native" ]]; then
    cmake_cross=(-DCMAKE_SYSTEM_NAME=Darwin -DCMAKE_SYSTEM_PROCESSOR="$arch")
  fi
  local build
  build="$([[ "$native" == arm64 ]] && echo aarch64 || echo x86_64)-apple-darwin"
  mkdir -p "$prefix/lib/pkgconfig"

  local flags="-arch $arch -mmacosx-version-min=$min_macos"
  export MACOSX_DEPLOYMENT_TARGET="$min_macos"
  export CC=clang CXX=clang++
  export CFLAGS="$flags -O2" CXXFLAGS="$flags -O2" LDFLAGS="$flags"
  # Only the libraries built here; nothing from Homebrew is linked in.
  export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
  unset PKG_CONFIG_PATH
  local cmake_args=(
    -DCMAKE_INSTALL_PREFIX="$prefix"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_ARCHITECTURES="$arch"
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$min_macos"
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DBUILD_SHARED_LIBS=OFF
    ${cmake_cross[@]+"${cmake_cross[@]}"}
  )
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
  (cd "$src" && LIBTOOLIZE=glibtoolize ./autogen.sh &&
    ./configure --prefix="$prefix" --build="$build" --host="$host" \
      --enable-static --disable-shared &&
    make -j"$jobs" install)

  log "$arch: x264"
  src="$(source_dir x264)"
  (cd "$src" &&
    ./configure --prefix="$prefix" --host="$host" \
      --enable-static --enable-pic --disable-cli \
      --disable-lsmash --disable-swscale --disable-ffms \
      --extra-cflags="$flags" --extra-ldflags="$flags" &&
    make -j"$jobs" install-lib-static)

  log "$arch: x265 (8, 10 and 12 bit in one library)"
  src="$(source_dir x265)"
  local x265="$work/$arch/x265"
  local high=(-DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DENABLE_CLI=OFF)
  mkdir -p "$x265/8bit"
  cmake -S "$src/source" -B "$x265/10bit" "${cmake_args[@]}" "${high[@]}" -DENABLE_HDR10_PLUS=ON
  make -C "$x265/10bit" -j"$jobs"
  cp "$x265/10bit/libx265.a" "$x265/8bit/libx265_main10.a"
  cmake -S "$src/source" -B "$x265/12bit" "${cmake_args[@]}" "${high[@]}" -DMAIN12=ON
  make -C "$x265/12bit" -j"$jobs"
  cp "$x265/12bit/libx265.a" "$x265/8bit/libx265_main12.a"
  cmake -S "$src/source" -B "$x265/8bit" "${cmake_args[@]}" \
    -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
    -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
    -DEXTRA_LINK_FLAGS=-L. "-DEXTRA_LIB=x265_main10.a;x265_main12.a"
  make -C "$x265/8bit" -j"$jobs"
  (cd "$x265/8bit" && mv libx265.a libx265_main.a &&
    libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a &&
    make install)

  log "$arch: SVT-AV1"
  src="$(source_dir svt-av1)"
  cmake -S "$src" -B "$work/$arch/svt-av1" -G Ninja "${cmake_args[@]}" \
    -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
  ninja -C "$work/$arch/svt-av1" install

  log "$arch: dav1d"
  src="$(source_dir dav1d)"
  local cross_file=()
  if [[ "$arch" != "$native" ]]; then
    cat > "$work/$arch/meson-cross.txt" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
cpp = ['clang++', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
nasm = 'nasm'

[built-in options]
c_args = ['-mmacosx-version-min=$min_macos']
c_link_args = ['-mmacosx-version-min=$min_macos']

[host_machine]
system = 'darwin'
cpu_family = '$([[ "$arch" == arm64 ]] && echo aarch64 || echo x86_64)'
cpu = '$arch'
endian = 'little'
EOF
    cross_file=(--cross-file "$work/$arch/meson-cross.txt")
  fi
  meson setup "$work/$arch/dav1d" "$src" ${cross_file[@]+"${cross_file[@]}"} \
    --prefix="$prefix" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false
  ninja -C "$work/$arch/dav1d" install

  log "$arch: FFmpeg"
  src="$(source_dir ffmpeg)"
  local cross=()
  if [[ "$arch" != "$native" ]]; then
    cross=(--enable-cross-compile --arch="$arch" --target-os=darwin)
  fi
  mkdir -p "$work/$arch/ffmpeg"
  (cd "$work/$arch/ffmpeg" &&
    "$src/configure" --prefix="$prefix" ${cross[@]+"${cross[@]}"} \
      --cc=clang --cxx=clang++ \
      --extra-cflags="$flags -I$prefix/include" \
      --extra-ldflags="$flags -L$prefix/lib" \
      --extra-libs="-lc++ -liconv" \
      --pkg-config-flags=--static \
      --extra-version=vidctrl \
      --enable-gpl --enable-version3 \
      --disable-autodetect --enable-pthreads \
      --enable-videotoolbox --enable-audiotoolbox \
      --enable-zlib --enable-bzlib --enable-iconv \
      --enable-libsvtav1 --enable-libx265 --enable-libx264 \
      --enable-libdav1d --enable-libmp3lame --enable-libzimg \
      --disable-ffplay --disable-doc --disable-debug \
      --enable-static --disable-shared &&
    make -j"$jobs" &&
    make install)
}

for arch in arm64 x86_64; do
  build_arch "$arch"
done

log "universal binaries"
out="$work/universal"
rm -rf "$out"
mkdir -p "$out"
for tool in ffmpeg ffprobe; do
  lipo -create "$work/arm64/prefix/bin/$tool" "$work/x86_64/prefix/bin/$tool" \
    -output "$out/$tool"
done

{
  echo "FFmpeg $version for macOS (Apple Silicon and Intel), built by build.sh."
  echo
  echo "Sources:"
  for entry in "${sources[@]}"; do
    IFS='|' read -r n file url sum <<< "$entry"
    echo "  $file  sha256 $sum"
    echo "    $url"
  done
  echo
  echo "Minimum macOS: $min_macos"
  echo
  "$work/arm64/prefix/bin/ffmpeg" -hide_banner -buildconf
} > "$out/BUILDINFO.txt"

rm -f "$dist"/*
(cd "$out" && zip -q -X "$dist/ffmpeg-$version-macos.zip" ffmpeg ffprobe BUILDINFO.txt)
(cd "$work/downloads" && cp "$root/build.sh" . &&
  tar -cf "$dist/ffmpeg-$version-macos-sources.tar" build.sh \
    $(for entry in "${sources[@]}"; do IFS='|' read -r n file url sum <<< "$entry"; echo "$file"; done))
(cd "$dist" && shasum -a 256 ./*)
