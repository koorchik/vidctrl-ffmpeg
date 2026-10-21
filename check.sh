#!/usr/bin/env bash
# Checks the FFmpeg that build.sh made, before it is published:
#
#   ./check.sh [folder with ffmpeg and ffprobe]     (default: work/universal)
#
# - both are universal binaries, linked only to what every Mac has;
# - nothing nonfree is in them;
# - they have what VidCtrl uses;
# - AV1 made with VidCtrl's archive settings looks the same as its original,
#   on each processor this Mac can run. SVT-AV1 3.1.2 failed this on Apple
#   chips (40.6 dB on this picture, where good builds give 43.8 to 45.1):
#   its Arm code made blockier pictures than its C code.
set -euo pipefail
# SVT-AV1 prints its settings unless told to report errors only.
export SVT_LOG=1

root="$(cd "$(dirname "$0")" && pwd)"
dir="${1:-$root/work/universal}"
ffmpeg="$dir/ffmpeg"
ffprobe="$dir/ffprobe"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

fail() {
  echo "FAIL: $*"
  failed=1
}

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

config="$("$ffmpeg" -hide_banner -buildconf)"
[[ "$config" != *--enable-nonfree* ]] || fail "built with --enable-nonfree"
[[ "$config" == *--enable-gpl* && "$config" == *--enable-version3* ]] ||
  fail "not configured as GPL v3"

encoders="$("$ffmpeg" -hide_banner -encoders)"
for name in libsvtav1 libx265 libx264 libmp3lame prores_ks dnxhd aac flac \
  pcm_s24le hevc_videotoolbox mjpeg ffv1; do
  grep -qE "^ \S+ $name " <<< "$encoders" || fail "no $name encoder"
done
grep -qE "^ \S+ libdav1d " <<< "$("$ffmpeg" -hide_banner -decoders)" ||
  fail "no libdav1d decoder"
filters="$("$ffmpeg" -hide_banner -filters)"
for name in zscale tonemap xpsnr scale; do
  grep -qE "^ \S+ $name " <<< "$filters" || fail "no $name filter"
done

# The archive goal's AV1 settings, as VidCtrl uses them
# (lib/core/scenarios/archive.dart and svtAv1ParamCandidates).
"$ffmpeg" -nostdin -hide_banner -loglevel error -y -f lavfi \
  -i testsrc2=s=1280x720:r=30 -frames:v 30 -c:v ffv1 -pix_fmt yuv420p \
  "$work/pattern.mkv"
byorder='settb=1/30,setpts=N,format=yuv420p10le'
for arch in arm64 x86_64; do
  if ! arch -"$arch" /usr/bin/true 2> /dev/null; then
    if [[ -n "${CHECK_EVERY_ARCH:-}" ]]; then
      fail "this Mac cannot run $arch, so it was not checked"
    else
      echo "skipped: this Mac cannot run $arch"
    fi
    continue
  fi
  arch -"$arch" "$ffmpeg" -nostdin -hide_banner -loglevel error -y \
    -i "$work/pattern.mkv" -map 0:v:0 -c:v libsvtav1 -preset 5 -crf 35 \
    -svtav1-params tune=0:enable-variance-boost=1:enable-qm=1:qm-min=0:keyint=10s:scd=1 \
    -pix_fmt yuv420p10le "$work/av1-$arch.mkv"
  score="$("$ffmpeg" -nostdin -hide_banner -nostats -i "$work/av1-$arch.mkv" \
    -i "$work/pattern.mkv" \
    -lavfi "[0:v:0]$byorder[d];[1:v:0]$byorder[r];[d][r]xpsnr=shortest=1" \
    -f null - 2>&1 | grep -oE 'XPSNR +y: +[0-9.inf]+' | awk '{print $3}')"
  echo "AV1 on $arch: XPSNR $score dB"
  awk -v s="$score" 'BEGIN { exit !(s == "inf" || s + 0 >= 42) }' ||
    fail "AV1 on $arch scores $score dB, below 42"
done

"$ffmpeg" -hide_banner -version | head -1
if [[ "$failed" -ne 0 ]]; then
  echo "The build is not fit to ship."
  exit 1
fi
echo "All checks passed."
