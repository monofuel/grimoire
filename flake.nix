{
  description = "Grimoire: voice-driven dual-screen ACP coding client";

  # Pinned to a revision whose AArch64 glibc (2.42) is not newer than the
  # handheld's, so cross-built binaries run there.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/f1e5c356f35d07e7b71a6b5e6c9338e0b029e0c0";

  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      # Desktop runtime: X11 for the two windows, OpenAL for the microphone and
      # speech playback, libcurl and OpenSSL for the speech endpoints.
      runtime = with pkgs; [ curl openal openssl libx11 libxcursor libxext libglvnd ];
    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        # The AArch64 cross compiler builds the RG DS Plus binary.
        packages = [ pkgs.gnumake pkgs.nim pkgs.pkgsCross.aarch64-multiplatform.stdenv.cc ];
        buildInputs = runtime;
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtime;
        NIX_LDFLAGS = "-rpath ${pkgs.lib.makeLibraryPath runtime}";
      };
    };
}
