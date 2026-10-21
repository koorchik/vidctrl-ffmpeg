#!/usr/bin/env bash
# Checks the FFmpeg that build.sh made, before it is published:
#
#   ./check.sh [folder with ffmpeg and ffprobe]
#
# The folder defaults to this system's build (work/macos, work/linux or
# work/windows). A Windows build is run under Wine when checked elsewhere.
#
# - both programs are linked only to what every computer of their kind has:
#   on macOS universal binaries and the system's libraries, on Linux the C
#   library, on Windows Windows' own DLLs;
# - nothing nonfree is in them;
# - they have what VidCtrl uses, the hardware encoders of their system too;
# - AV1 made with VidCtrl's archive settings comes as close to its original
#   as it should (XPSNR above 44 dB on this picture), on each processor this
#   computer can run. SVT-AV1 3.1.2 failed this on Apple chips (42.5 dB,
#   where good builds give 45.1 to 46.2): its Arm code made blockier
#   pictures than its C code.
set -euo pipefail
# SVT-AV1 prints its settings unless told to report errors only.
export SVT_LOG=1

root="$(cd "$(dirname "$0")" && pwd)"
on_windows=""
case "$(uname -s)" in
  Darwin) default=macos ;;
  MINGW* | MSYS* | CYGWIN*)
    default=windows
    on_windows=1
    # Git Bash would rewrite the filter graphs' colons and slashes.
    export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
    ;;
  *) default=linux ;;
esac
dir="${1:-$root/work/$default}"
run=()
if [[ -f "$dir/ffmpeg.exe" ]]; then
  kind=windows
  ffmpeg="$dir/ffmpeg.exe"
  ffprobe="$dir/ffprobe.exe"
  if [[ -z "$on_windows" ]]; then
    run=(wine)
    export WINEDEBUG=-all
  fi
elif [[ "$default" == macos ]]; then
  kind=macos
  ffmpeg="$dir/ffmpeg"
  ffprobe="$dir/ffprobe"
else
  kind=linux
  ffmpeg="$dir/ffmpeg"
  ffprobe="$dir/ffprobe"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

fail() {
  echo "FAIL: $*"
  failed=1
}

# Runs the build's ffmpeg, under Wine where needed.
ff() {
  ${run[@]+"${run[@]}"} "$ffmpeg" -nostdin -hide_banner "$@"
}

# A file's path as the build's ffmpeg wants it.
path() {
  if [[ -n "$on_windows" ]]; then cygpath -w "$1"; else echo "$1"; fi
}

case "$kind" in
  macos)
    for tool in "$ffmpeg" "$ffprobe"; do
      archs="$(lipo -archs "$tool")"
      [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] ||
        fail "$(basename "$tool") is not universal: $archs"
      for arch in arm64 x86_64; do
        others="$(otool -arch "$arch" -L "$tool" | tail -n +2 |
          grep -vE '^\s+(/usr/lib/|/System/Library/)' || true)"
        [[ -z "$others" ]] ||
          fail "$(basename "$tool") ($arch) links to libraries a Mac does not have: $others"
      done
    done
    ;;
  linux)
    for tool in "$ffmpeg" "$ffprobe"; do
      others="$(readelf -d "$tool" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' |
        grep -vxE 'libc\.so\.6|libm\.so\.6|libmvec\.so\.1|ld-linux-x86-64\.so\.2|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1' || true)"
      [[ -z "$others" ]] ||
        fail "$(basename "$tool") links to libraries not every Linux has: $others"
      # VidCtrl's Linux download is built on Ubuntu 24.04, whose C library is
      # 2.39; FFmpeg must not ask for a newer one.
      glibc="$(objdump -T "$tool" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -V | tail -1)"
      [[ "$(printf '%s\n' "$glibc" GLIBC_2.39 | sort -V | tail -1)" == GLIBC_2.39 ]] ||
        fail "$(basename "$tool") needs $glibc, newer than Ubuntu 24.04's"
    done
    ;;
  windows)
    objdump="$(command -v x86_64-w64-mingw32-objdump || command -v objdump || true)"
    if [[ -z "$objdump" ]]; then
      echo "skipped: no objdump to list the DLLs (checked where the build is made)"
    else
      for tool in "$ffmpeg" "$ffprobe"; do
        others="$("$objdump" -p "$tool" | sed -n 's/^\s*DLL Name: //p' |
          grep -vixE 'kernel32\.dll|user32\.dll|advapi32\.dll|bcrypt\.dll|ole32\.dll|oleaut32\.dll|shell32\.dll|shlwapi\.dll|gdi32\.dll|ws2_32\.dll|msvcrt\.dll|ucrtbase\.dll|api-ms-win-[a-z0-9-]+\.dll|version\.dll|cfgmgr32\.dll|setupapi\.dll|psapi\.dll|secur32\.dll|crypt32\.dll' || true)"
        [[ -z "$others" ]] ||
          fail "$(basename "$tool") needs DLLs Windows does not have: $others"
      done
    fi
    ;;
esac

config="$(ff -buildconf)"
[[ "$config" != *--enable-nonfree* ]] || fail "built with --enable-nonfree"
[[ "$config" == *--enable-gpl* && "$config" == *--enable-version3* ]] ||
  fail "not configured as GPL v3"

# Every encoder VidCtrl names (lib/core in VidCtrl).
wanted="libsvtav1 libx265 libx264 libmp3lame prores_ks dnxhd aac flac alac
  pcm_s16le pcm_s24le pcm_s32le pcm_f32le mjpeg ffv1"
case "$kind" in
  macos) wanted+=" hevc_videotoolbox h264_videotoolbox" ;;
  linux) wanted+=" av1_nvenc hevc_nvenc h264_nvenc" ;;
  windows)
    wanted+=" av1_nvenc hevc_nvenc h264_nvenc av1_qsv hevc_qsv h264_qsv
      av1_amf hevc_amf h264_amf"
    ;;
esac
encoders="$(ff -encoders | tr -d '\r')"
for name in $wanted; do
  grep -qE "^ \S+ $name " <<< "$encoders" || fail "no $name encoder"
done
grep -qE "^ \S+ libdav1d " <<< "$(ff -decoders | tr -d '\r')" ||
  fail "no libdav1d decoder"
filters="$(ff -filters | tr -d '\r')"
for name in zscale tonemap xpsnr libvmaf scale; do
  grep -qE "^ \S+ $name " <<< "$filters" || fail "no $name filter"
done

# The archive goal's AV1 settings, as VidCtrl uses them
# (lib/core/scenarios/archive.dart and svtAv1ParamCandidates).
ff -loglevel error -y -f lavfi -i testsrc2=s=1280x720:r=30 -frames:v 30 \
  -c:v ffv1 -pix_fmt yuv420p "$(path "$work/pattern.mkv")"
# Packed rows of a width that is a multiple of 32: FFmpeg's xpsnr misreads
# others. The original goes first: xpsnr weighs by how busy it is.
byorder='settb=1/30,setpts=N,crop=trunc(iw/32)*32:ih:0:0,format=yuv420p10le,copy'
if [[ "$kind" == macos ]]; then archs=(arm64 x86_64); else archs=(x86_64); fi
for arch in "${archs[@]}"; do
  prefix=()
  if [[ "$kind" == macos ]]; then
    if ! arch -"$arch" /usr/bin/true 2> /dev/null; then
      if [[ -n "${CHECK_EVERY_ARCH:-}" ]]; then
        fail "this Mac cannot run $arch, so it was not checked"
      else
        echo "skipped: this Mac cannot run $arch"
      fi
      continue
    fi
    prefix=(arch -"$arch")
  fi
  ${prefix[@]+"${prefix[@]}"} ${run[@]+"${run[@]}"} "$ffmpeg" -nostdin \
    -hide_banner -loglevel error -y -i "$(path "$work/pattern.mkv")" \
    -map 0:v:0 -c:v libsvtav1 -preset 5 -crf 35 \
    -svtav1-params tune=0:enable-variance-boost=1:enable-qm=1:qm-min=0:keyint=10s:scd=1 \
    -pix_fmt yuv420p10le "$(path "$work/av1-$arch.mkv")"
  scores="$(ff -nostats -i "$(path "$work/av1-$arch.mkv")" \
    -i "$(path "$work/pattern.mkv")" \
    -lavfi "[0:v:0]$byorder,split[d][dv];[1:v:0]$byorder,split[r][rv];[r][d]xpsnr=shortest=1[x];[dv][rv]libvmaf=model=version=vmaf_v0.6.1[v]" \
    -map '[x]' -map '[v]' -f null - 2>&1 | tr -d '\r')"
  score="$(grep -oE 'XPSNR +y: +[0-9.inf]+' <<< "$scores" | awk '{print $3}' || true)"
  vmaf="$(grep -oE 'VMAF score: +[0-9.]+' <<< "$scores" | awk '{print $3}' || true)"
  echo "AV1 on $arch: XPSNR ${score:-none} dB, VMAF ${vmaf:-none}"
  [[ -n "$vmaf" ]] || fail "VMAF gave no score: its built-in models are missing"
  awk -v s="$score" 'BEGIN { exit !(s == "inf" || s + 0 > 44) }' ||
    fail "AV1 on $arch scores ${score:-nothing}, not above 44 dB"
done

ff -version | head -1 | tr -d '\r'
if [[ "$failed" -ne 0 ]]; then
  echo "The build is not fit to ship."
  exit 1
fi
echo "All checks passed."
