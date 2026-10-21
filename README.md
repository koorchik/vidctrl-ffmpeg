# FFmpeg for VidCtrl

The `ffmpeg` and `ffprobe` that [VidCtrl](https://camctrl.app/vidctrl)
ships on macOS, Linux and Windows: static, with only the libraries VidCtrl
uses, and with library versions chosen here, the same on every system.

VidCtrl used to ship ready-made builds. The macOS one carried SVT-AV1
3.1.2, which made blockier AV1 on Apple chips than on other processors at
the same file size: its Arm code encoded worse than its own C code. VidCtrl
now builds its own on every system, so that what it measured is what it
ships, and every build passes the same check before it is published.

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
| libvmaf | 3.2.1 (models built in) | VMAF in "Compare with the original" |
| zlib | 1.3.2 | Linux and Windows (macOS has its own) |
| NVIDIA codec headers | 12.1.14.1 | NVIDIA encoders, Linux and Windows |
| AMF headers | 1.4.36 | AMD encoders, Windows |
| libvpl | 2.16.0 | Intel encoders, Windows |

The hardware encoders' headers are the oldest that have what VidCtrl uses,
so that the oldest drivers work: NVIDIA 530 on Linux and 531.61 on Windows.
On macOS, VideoToolbox, AudioToolbox, bzip2 and iconv come from the system.

The builds are GPL version 3 (`--enable-gpl --enable-version3`), with
nothing nonfree, and need:

- macOS 12 or newer (Apple Silicon and Intel in one universal binary), as
  VidCtrl does;
- Linux x86-64 with the C library of Ubuntu 24.04 or newer, as VidCtrl's
  Linux download does; nothing else;
- Windows x64; nothing but Windows' own DLLs.

## Building

```sh
./build.sh macos     # on a Mac; about half an hour on an M1
./build.sh linux     # on Ubuntu 24.04
./build.sh windows   # on Ubuntu 24.04, cross-compiled
./check.sh           # tells whether this system's build is fit to ship
```

The tools each needs are listed at the top of `build.sh`. `build.sh`
downloads each source, checks it against the checksum written in the
script and builds. It leaves in `dist/`:

- `ffmpeg-<version>-<system>.zip`: `ffmpeg`, `ffprobe` and
  `BUILDINFO.txt`, which lists every source and the configure options;
- `ffmpeg-<version>-sources.tar`: every source tarball and the script, the
  complete source of the binaries.

`check.sh` checks that the programs are linked only to what every computer
of their kind has, that they are GPL and not nonfree, and that they have
the encoders (the hardware ones of their system too), decoders and filters
VidCtrl uses. It also checks that AV1 made with VidCtrl's archive settings
looks the same as its original (XPSNR above 44 dB on a test picture), on
each processor the computer can run; SVT-AV1 3.1.2 failed this on Apple
chips. On Linux it checks a Windows build under Wine (`./check.sh
work/windows`).

## Publishing

Actions → Build → Run workflow, with "Publish" ticked. The workflow builds
and checks each system on GitHub's machines: the Mac is Apple Silicon,
where Rosetta lets `check.sh` run the Intel half too; the Windows build is
checked under Wine and then on Windows itself. It then makes one release
named after `version` in `build.sh`, holding the three zips and the
sources.

VidCtrl's `tool/fetch_ffmpeg.sh` pins each zip by its address and SHA-256,
so every clone and every VidCtrl release gets the same bytes. To ship a new
version:

1. Change the pins in `build.sh` and raise `version`.
2. Run the workflow with Publish.
3. Change the release and the checksums in VidCtrl's
   `tool/fetch_ffmpeg.sh`, and the versions in its
   `assets/licenses/ffmpeg.txt`.

## Licence

The binaries are under the GNU GPL version 3. Each release carries the
source of every part. A licence for these scripts is not chosen yet.
