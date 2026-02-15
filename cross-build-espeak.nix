# Cross-compile a minimal espeak-ng for Kobo (armv7l)
# Usage: nix-build cross-build-espeak.nix --no-out-link
# Then: ls $(nix-build cross-build-espeak.nix --no-out-link)/bin/
let
  pkgs = import <nixpkgs> {};
  crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
in
(crossPkgs.espeak-ng.override {
  # Disable all the heavy/failing optional dependencies
  pcaudiolibSupport = false;   # No audio output lib (we write to wav files)
  sonicSupport = false;        # No sonic speed adjustment
  mbrolaSupport = false;       # No MBROLA voice support
}).overrideAttrs (old: {
  # Remove the postInstall that wraps with alsa-plugins (fails cross-compile
  # and unnecessary for Kobo where we only use --stdout / -w file.wav)
  postInstall = "";
})
