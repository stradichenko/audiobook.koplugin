# Cross-compile a STATIC espeak-ng for legacy speaker Kindles
# (K2/K3/DXG, K4, Touch, PW1: soft-float userland, kernel 2.6.x, ARMv7-A).
#
# Static musl: no dynamic loader and no GLIBC floor, so it runs where the
# bundled Kobo espeak-ng (armhf glibc 2.42 via ld-linux wrapper) cannot.
# It reuses the existing bundled espeak-ng/share voice data at runtime
# through ESPEAK_DATA_PATH, so BOTH espeak builds must be built from the
# same nixpkgs pin (the data format version must match).  The pin below is
# the one cross-build-espeak.nix uses.
#
# The verified binary is vendored at espeak-ng-legacy/bin/espeak-ng; this
# recipe exists so it can be rebuilt from source.  Requires
# NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 (the static scope's platform check is
# conservative; the build itself works).
#
# Usage: NIXPKGS_ALLOW_UNSUPPORTED_SYSTEM=1 nix-build cross-build-espeak-legacy.nix --no-out-link
let
  nixpkgsSrc = fetchTarball "https://github.com/NixOS/nixpkgs/archive/255a186666b6130ddddf8ad749887102a0820914.tar.gz";
  pkgs = import nixpkgsSrc {};
  crossStatic = pkgs.pkgsCross.armv7l-hf-multiplatform.pkgsStatic;
in
(crossStatic.espeak-ng.override {
  pcaudiolibSupport = false;   # no audio lib; we only write wav files
  sonicSupport = false;
  mbrolaSupport = false;       # MBROLA is the Kobo build's concern, not legacy
  speechPlayerSupport = false;
  # The static scope makes even build-side helpers static, which explodes
  # in gobject-introspection; the native helper and build tools must be
  # normal build-arch packages.
  buildPackages = pkgs;
}).overrideAttrs (old: {
  # Skip the alsa-plugins wrapper postInstall.
  postInstall = "";
  doCheck = false;
  # Static binary: shared libs off, fully link the executable
  # (later -D flags override the ON from the default flags).
  cmakeFlags = (old.cmakeFlags or []) ++ [
    "-DBUILD_SHARED_LIBS=OFF"
    "-DCMAKE_EXE_LINKER_FLAGS=-static"
  ];
})
