# Cross-compile the sanoTTS engine server for Kobo (armv7l), static musl.
# Pinned to the same nixpkgs revision as the other audiobook.koplugin cross
# builds so the runner reuses the cached toolchain instead of building a
# different one from source. sanotts/mcu must be fetched first (the packaging
# script does this at the pinned sanoTTS commit).
# Usage: nix-build cross-build-snt-server.nix --no-out-link
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform.pkgsStatic;
  sanoDir = ./sanotts;
in

crossPkgs.stdenv.mkDerivation {
  pname = "snt-server";
  version = "0.2.0";

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -O2 -std=c99 -I${sanoDir}/mcu/include -I${sanoDir}/mcu/src -DFSD_FAST_MATH"
    $CC -static -o snt_server ${sanoDir}/snt_server.c ${sanoDir}/mcu/src/snt_tts.c ${sanoDir}/mcu/src/snt_kernels_ref.c ${sanoDir}/mcu/ports/host/snt_port_host.c -lm
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp snt_server $out/bin/
  '';
}
