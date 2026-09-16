# Cross-compile a minimal STATIC ffmpeg for legacy speaker Kindles
# (K2/K3/DXG, K4, Touch, PW1: soft-float userland, kernel 2.6.x, ARMv7-A).
#
# Static musl: no dynamic loader, no GLIBC version floor, no .note.ABI-tag
# kernel check, so the same binary also serves as the crash-fallback decoder
# on any other ARMv7 platform. FPU pinned to vfpv3-d16: the Cortex-A8 in
# these devices has VFPv3 only and dies on VFPv4 fused-MAC instructions.
#
# The verified binary is vendored at bin/ffmpeg-legacy; this recipe exists
# so it can be rebuilt from source (bump the ffmpeg version there and here
# together, and re-run the verification: readelf tags, qemu-arm -cpu
# cortex-a8 decode matrix, syscall audit).
#
# Usage: nix-build cross-build-ffmpeg-legacy.nix --no-out-link
let
  # Pin nixpkgs to a known-good commit (nixpkgs-unstable, 2026-03-22),
  # the same pin every other cross-build-*.nix in this repo uses.
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossStatic = pkgs.pkgsCross.armv7l-hf-multiplatform.pkgsStatic;
in
crossStatic.stdenv.mkDerivation {
  pname = "ffmpeg-legacy";
  version = "7.0.2";

  src = pkgs.fetchurl {
    url = "https://www.ffmpeg.org/releases/ffmpeg-7.0.2.tar.xz";
    hash = "sha256-hkZRW2OKOtMD4jr2o1h3NER8uPwKDAZOzbjpXE/Ys4k=";
  };

  # ffmpeg's configure rejects the --build/--host flags the cross stdenv
  # appends to configureFlags, so all flags are passed inline here.
  # -Os + gc-sections for size; FPU pinned so no VFPv4/NEON fused-MAC
  # instructions can ever be emitted (Cortex-A8 has VFPv3/NEON only).
  # The nix sandbox has no native "cc" on PATH, but ffmpeg builds its
  # table generators with a host compiler, so --host-cc must point at the
  # build-arch compiler explicitly.
  nativeBuildInputs = [ pkgs.buildPackages.stdenv.cc ];
  hardeningDisable = [ "all" ];
  configurePhase = ''
    ./configure \
      --prefix=$out \
      --enable-cross-compile \
      --cross-prefix=${crossStatic.stdenv.cc.targetPrefix} \
      --host-cc=${pkgs.buildPackages.stdenv.cc}/bin/cc \
      --arch=arm \
      --target-os=linux \
      --enable-static \
      --disable-shared \
      --enable-small \
      --disable-everything \
      --disable-doc \
      --disable-debug \
      --disable-network \
      --disable-autodetect \
      --disable-avdevice \
      --disable-swscale \
      --disable-postproc \
      --enable-ffmpeg \
      --disable-ffprobe \
      --disable-ffplay \
      --enable-protocol=file,pipe \
      --enable-muxer=pcm_s16le,pcm_s16be,wav \
      --enable-demuxer=mov,mp3,ogg,flac,asf,wav,matroska,aac \
      --enable-decoder=aac,aac_latm,mp3,mp3float,mp2,flac,vorbis,opus,ac3,eac3,alac,wmav1,wmav2,pcm_s16le,pcm_s16be,pcm_u8,pcm_f32le,pcm_alaw,pcm_mulaw \
      --enable-encoder=pcm_s16le,pcm_s16be \
      --enable-parser=aac,mpegaudio,ac3,vorbis,opus,flac \
      --enable-filter=aformat,anull,aresample,atempo,volume,apad,adelay \
      --extra-cflags="-Os -ffunction-sections -fdata-sections -mfpu=vfpv3-d16 -march=armv7-a" \
      --extra-ldflags="-static -Wl,--gc-sections"
  '';

  enableParallelBuilding = true;
  dontStrip = false;

  installPhase = ''
    mkdir -p $out/bin
    install -m755 ffmpeg $out/bin/ffmpeg
  '';
}
