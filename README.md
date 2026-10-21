# FFmpeg for VidCtrl on macOS

The `ffmpeg` and `ffprobe` that [VidCtrl](https://camctrl.app/vidctrl)
ships on macOS: static, universal (Apple Silicon and Intel), with only the
libraries VidCtrl uses, and with library versions chosen here.

VidCtrl used to ship a ready-made build. That build's SVT-AV1 (3.1.2) made
blockier AV1 on Apple chips than on other processors, at the same file size:
its Arm code encoded worse than its own C code. SVT-AV1 4.2 does not have
this fault. The builder kept 3.1.2, so VidCtrl now builds its own.

## What is in it

| Part | Version | For |
|---|---|---|
| FFmpeg | 8.1.3 | everything else |
| SVT-AV1 | 4.2.0 | AV1, "For the archive" |
| x265 | 4.3 (8, 10 and 12 bit) | HEVC |
| x264 | stable `b35605a` | H.264, "Send to a phone" |
| dav1d | 1.5.4 | reading AV1 |
| zimg | 3.0.6 | HDR to SDR (`zscale`) |
| LAME | 3.100 | MP3, "Get the sound" |

VideoToolbox, AudioToolbox, zlib, bzip2 and iconv come from macOS itself.
The build is GPL version 3 (`--enable-gpl --enable-version3`), with nothing
nonfree. The binaries need macOS 12 or newer, as VidCtrl does.

## Building

On a Mac with Xcode's command line tools:

```sh
brew install cmake meson ninja nasm pkgconf autoconf automake libtool
./build.sh     # about half an hour on an M1; builds both halves
./check.sh     # tells whether the result is fit to ship
```

`build.sh` downloads each source, checks it against the checksum written in
the script, builds both halves and joins them with `lipo`. It leaves in
`dist/`:

- `ffmpeg-<version>-macos.zip`: `ffmpeg`, `ffprobe` and `BUILDINFO.txt`,
  which lists every source and the configure options;
- `ffmpeg-<version>-macos-sources.tar`: every source tarball and the script,
  the complete source of the binaries.

`check.sh` checks that the binaries are universal, linked only to what every
Mac has, GPL and not nonfree, and have the encoders, decoders and filters
VidCtrl uses. It also checks that AV1 made with VidCtrl's archive settings
looks the same as its original (XPSNR of at least 42 dB on a test picture),
on each processor the Mac can run. That last check is the one SVT-AV1 3.1.2
failed on Apple chips.

## Publishing

Actions → Build → Run workflow, with "Publish" ticked. The workflow builds
and checks on GitHub's Apple Silicon Mac, where Rosetta lets `check.sh` run
the Intel half too. It then makes a release named after `version` in
`build.sh`, holding both files from `dist/`.

VidCtrl's `tool/fetch_ffmpeg.sh` pins the zip by its address and SHA-256, so
every clone and every VidCtrl release gets the same bytes. To ship a new
version:

1. Change the pins in `build.sh` and raise `version`.
2. Run the workflow with Publish.
3. Change the address and checksum in VidCtrl's `tool/fetch_ffmpeg.sh`, and
   the versions in its `assets/licenses/ffmpeg.txt`.

## Licence

The binaries are under the GNU GPL version 3. Each release carries the
source of every part. A licence for these scripts is not chosen yet.
