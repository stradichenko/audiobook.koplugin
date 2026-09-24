# Cross-compile the sanoTTS-jp engine server for Kobo/Kindle (armv7l), static
# musl. Pinned to the same nixpkgs revision as the other audiobook.koplugin
# cross builds so the runner reuses the cached toolchain. The core sources are
# vendored in sanotts-jp/csrc (see sanotts-jp/PROVENANCE.md); no weights or
# dictionary data are part of this build or of the release zip — the user
# downloads those in-app.
# Usage: nix-build cross-build-snt-jp-server.nix --no-out-link
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform.pkgsStatic;
  jpDir = ./sanotts-jp;
in

crossPkgs.stdenv.mkDerivation {
  pname = "snt-jp-server";
  version = "0.1.0";

  dontUnpack = true;
  dontConfigure = true;

  buildPhase = ''
    export NIX_CFLAGS_COMPILE="$NIX_CFLAGS_COMPILE -O2 -std=c99 -D_POSIX_C_SOURCE=200809L -DCHARSET_UTF_8 -I${jpDir}/csrc -I${jpDir}/csrc/openjtalk"
    $CC -static -o snt_jp_server ${jpDir}/snt_jp_server.c ${jpDir}/csrc/saanotts.c ${jpDir}/csrc/saanotts_stream.c ${jpDir}/csrc/fft.c ${jpDir}/csrc/saanotts_int8.c ${jpDir}/csrc/g2p.c ${jpDir}/csrc/jdict.c ${jpDir}/csrc/accent.c ${jpDir}/csrc/njd_rules.c ${jpDir}/csrc/label_ids.c ${jpDir}/csrc/openjtalk/*.c -lm
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp snt_jp_server $out/bin/
  '';
}
