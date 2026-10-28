{
  description = "Audiobook Read-Along Plugin for KOReader -- TTS with word highlighting";

  inputs = {
    # Pin nixpkgs to the same commit used in cross-build-espeak.nix
    nixpkgs.url = "github:NixOS/nixpkgs/255a186666b6130ddddf8ad749887102a0820914";
  };

  outputs = { self, nixpkgs }:
    let
      # Systems where we can *build* (the output is always armv7l)
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

      # Cross-compiled espeak-ng for Kobo (armv7l, glibc, minimal deps)
      mkEspeakKobo = pkgs:
        let
          crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
        in
        (crossPkgs.espeak-ng.override {
          pcaudiolibSupport = false;
          sonicSupport = false;
          mbrolaSupport = true;
        }).overrideAttrs (_old: {
          postInstall = "";
        });

      # Cross-compiled bluez-alsa for Kobo (armv7l, minimal -- no AAC)
      # Provides BT audio bridging on BlueZ Kobo devices (Libra 2, Io)
      mkBluealsaKobo = pkgs:
        let
          crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
        in
        (crossPkgs.bluez-alsa.override {
          aacSupport = false;
        }).overrideAttrs (old: {
          nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.glib ];
          configureFlags = (old.configureFlags or []) ++ [
            "--disable-systemd"
            "--disable-hcitop"
            "--disable-rfcomm"
          ];
        });

      # Cross-compiled kindle-gst-play for Kindle (armv7l, dlopen, no headers)
      mkKindleGstPlay = pkgs:
        let
          crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
        in
        crossPkgs.stdenv.mkDerivation {
          pname = "kindle-gst-play";
          version = "0.1.0";
          src = ./kindle;
          buildInputs = [];
          buildPhase = ''
            $CC -O2 -Wall -Wextra -Wno-unused-parameter \
                -Wl,--dynamic-linker=/lib/ld-linux-armhf.so.3 \
                -Wl,-E -Wl,--version-script=glibc_compat.map \
                -o gst-play gst-play.c -ldl
          '';
          installPhase = ''
            mkdir -p $out/bin
            cp gst-play $out/bin/
          '';
          meta = with pkgs.lib; {
            description = "Minimal GStreamer WAV player for Kindle via mixersink";
            license = licenses.agpl3Only;
          };
        };

      # Plugin source files to bundle
      pluginFiles = [
        "main.lua"
        "textparser.lua"
        "ttsengine.lua"
        "highlightmanager.lua"
        "synccontroller.lua"
        "playbackbar.lua"
        "menubuilder.lua"
        "btmanager.lua"
        "btui.lua"
        "btmediacontrol.lua"
        "utils.lua"
        "wavutils.lua"
        "piperqueue.lua"
        "bugreport.lua"
        "androidtts.lua"
        "_meta.lua"
        "mediaengine.lua"
        "mediasync.lua"
        "audiobookplayer.lua"
        "m4bparser.lua"
        "mediaaligner.lua"
        "transcoder.lua"
        "benchmarkrunner.lua"
        "downloader.lua"
        "epubmediaoverlay.lua"
        "updater.lua"
        "sessionrecorder.lua"
      ];
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [
              # libadwaita's test-preferences-group test crashes with SIGTRAP in
              # headless CI environments (no display server). It is pulled in
              # transitively via alsa-plugins -> ffmpeg -> sdl3 -> zenity.
              (self: super: {
                libadwaita = super.libadwaita.overrideAttrs (old: {
                  doCheck = false;
                });
              })
            ];
          };
          espeakKobo = mkEspeakKobo pkgs;
          bluealsaKobo = mkBluealsaKobo pkgs;
          kindleGstPlay = mkKindleGstPlay pkgs;
        in
        {
          # Cross-compiled espeak-ng binary + data for Kobo armv7l
          espeak-ng-kobo = espeakKobo;

          # Cross-compiled bluez-alsa for Kobo armv7l (uses Nix glibc)
          # Note: this build may be incompatible with older devices (glibc < 2.28).
          # For Clara 2E and similar devices, use bluealsa-kobo-compat below.
          bluealsa-kobo = bluealsaKobo;

          # Cross-compiled bluez-alsa built against Debian Jessie glibc 2.19.
          # This is the recommended build for distribution; it works on all
          # Kobo devices including Clara 2E (goldfinch).
          # Requires: nix build .#bluealsa-kobo-compat --no-sandbox
          bluealsa-kobo-compat = import ./cross-build-bluealsa-compat.nix;

          # Cross-compiled GStreamer WAV player for Kindle armv7l
          kindle-gst-play = kindleGstPlay;

          # Full plugin bundle with espeak-ng (Lua + binaries + data)
          kobo-bundle =
            let
              crossPkgs = pkgs.pkgsCross.armv7l-hf-multiplatform;
              crossGlibc = crossPkgs.stdenv.cc.libc;
              crossGcc = crossPkgs.stdenv.cc.cc.lib;
            in
            pkgs.stdenvNoCC.mkDerivation {
            pname = "audiobook-koplugin-bundle";
            version = "0.1.0";
            src = ./.;

            nativeBuildInputs = [ pkgs.binutils ];

            buildPhase = "true";

            installPhase = ''
              dest=$out/audiobook.koplugin
              espeak=$dest/espeak-ng
              mkdir -p "$espeak/bin" "$espeak/lib" \
                       "$espeak/share/espeak-ng-data/lang/gmw" \
                       "$espeak/share/espeak-ng-data/voices"

              # Plugin Lua files
              for f in ${builtins.concatStringsSep " " pluginFiles}; do
                [ -f "$src/$f" ] && cp "$src/$f" "$dest/"
              done

              # Android TTS helper (Java source + build script)
              if [ -d "$src/android" ]; then
                mkdir -p "$dest/android"
                cp "$src/android/TtsHelper.java" "$dest/android/"
                cp "$src/android/build-dex.sh" "$dest/android/"
                [ -f "$src/android/tts_helper.dex" ] && cp "$src/android/tts_helper.dex" "$dest/android/"
              fi

              # espeak-ng binary
              cp ${espeakKobo}/bin/espeak-ng "$espeak/bin/"

              # espeak-ng shared library (versioned .so → symlinks)
              espeakSo=$(find ${espeakKobo}/lib -name 'libespeak-ng.so.*.*.*' ! -type l | head -1)
              espeakSoName=$(basename "$espeakSo")
              cp "$espeakSo" "$espeak/lib/"
              (cd "$espeak/lib" && ln -sf "$espeakSoName" libespeak-ng.so.1 \
                                && ln -sf libespeak-ng.so.1 libespeak-ng.so)

              # Bundled glibc from cross toolchain
              for lib in ld-linux-armhf.so.3 libc.so.6 libm.so.6 libdl.so.2 \
                         libpthread.so.0 librt.so.1; do
                src="${crossGlibc}/lib/$lib"
                [ -f "$src" ] && cp "$src" "$espeak/lib/"
              done
              chmod +x "$espeak/lib/ld-linux-armhf.so.3"

              # GCC runtime libs (libstdc++, libgcc_s)
              for lib in libstdc++.so.6 libgcc_s.so.1; do
                src=$(find ${crossGcc} -name "$lib" -not -type l | head -1)
                if [ -n "$src" ]; then
                  cp "$src" "$espeak/lib/$lib"
                fi
              done

              # Phoneme data (required for all languages)
              for f in phondata phonindex phontab intonations; do
                cp ${espeakKobo}/share/espeak-ng-data/$f "$espeak/share/espeak-ng-data/"
              done

              # English dictionary
              cp ${espeakKobo}/share/espeak-ng-data/en_dict "$espeak/share/espeak-ng-data/"

              # English voice definitions
              cp -r ${espeakKobo}/share/espeak-ng-data/lang/gmw/en* \
                "$espeak/share/espeak-ng-data/lang/gmw/" 2>/dev/null || true

              # Voice variants
              if [ -d "${espeakKobo}/share/espeak-ng-data/voices/!v" ]; then
                cp -r "${espeakKobo}/share/espeak-ng-data/voices/!v" \
                  "$espeak/share/espeak-ng-data/voices/"
              fi

              # ── BlueALSA (Bluetooth audio bridge for BlueZ Kobo) ──
              ba=$dest/bluealsa
              mkdir -p "$ba/bin" "$ba/lib/alsa-lib" "$ba/etc/alsa/conf.d" "$ba/share/dbus-1/system.d"
              cp ${bluealsaKobo}/bin/bluealsa "$ba/bin/"
              cp ${bluealsaKobo}/lib/alsa-lib/libasound_module_pcm_bluealsa.so "$ba/lib/alsa-lib/"
              cp ${bluealsaKobo}/lib/alsa-lib/libasound_module_ctl_bluealsa.so "$ba/lib/alsa-lib/"
              cp ${bluealsaKobo}/etc/alsa/conf.d/20-bluealsa.conf "$ba/etc/alsa/conf.d/"
              cp ${bluealsaKobo}/share/dbus-1/system.d/bluealsa.conf "$ba/share/dbus-1/system.d/"

              # BlueALSA runtime deps (libsbc, libglib, libdbus, libbluetooth)
              # These are cross-compiled and linked automatically by Nix.
              # Bundle them so the Kobo's old system libs don't conflict.
              for dep in ${crossPkgs.sbc}/lib/libsbc.so* \
                         ${crossPkgs.glib}/lib/libglib-2.0.so* \
                         ${crossPkgs.glib}/lib/libgobject-2.0.so* \
                         ${crossPkgs.dbus}/lib/libdbus-1.so* \
                         ${crossPkgs.bluez}/lib/libbluetooth.so*; do
                [ -e "$dep" ] && cp -P "$dep" "$ba/lib/" 2>/dev/null || true
              done
              # Resolve symlinks to real files
              for f in "$ba/lib/"*.so*; do
                if [ -L "$f" ]; then
                  target=$(readlink -f "$f")
                  [ -f "$target" ] && cp "$target" "$f"
                fi
              done
            '';

            meta = with pkgs.lib; {
              description = "Audiobook Read-Along KOReader plugin bundle for Kobo";
              license = licenses.agpl3Only;
              platforms = platforms.linux;
            };
          };

          default = self.packages.${system}.espeak-ng-kobo;
        }
      );

      # Dev shell with tools used by package-for-kobo.sh and development
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              binutils        # readelf (used by package-for-kobo.sh)
              curl             # downloading Piper voices
              file             # inspecting binaries
              jdk17            # javac for android/build-dex.sh (d8 comes from the Android SDK)
              lua5_4           # local Lua testing
              luajit           # closer to KOReader's runtime
            ];

            shellHook = ''
              echo "audiobook.koplugin dev shell"
              echo "  nix build .#espeak-ng-kobo   -- cross-compile espeak-ng for Kobo"
              echo "  nix build .#kobo-bundle       -- full plugin bundle with espeak-ng"
              echo "  bash package-for-kobo.sh      -- package with optional Piper"
            '';
          };
        }
      );
    };
}
