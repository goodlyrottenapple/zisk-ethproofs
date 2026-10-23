{
  description = "ethproofs-client: ZisK EthProofs prover client with the Monad adapter";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = pkgs.lib;

      # ZisK's C++ STARK library links -lmpi and -liomp5. The stock nixpkgs
      # packages carry far more in their runtime closure than the client uses:
      # OpenMPI's Fortran bindings and Omni-Path/libfabric transports, and
      # libomp's OMPD debugger plugin, which depends on Python. Without them
      # the client's closure is roughly half the size.
      openmpi = (pkgs.openmpi.override { fortranSupport = false; fabricSupport = false; })
        .overrideAttrs (old: {
          # nixpkgs installs the oshmem Fortran wrappers regardless of
          # fortranSupport, and they dangle without it.
          postInstall = old.postInstall + "rm -f $out/bin/shmemfort $out/bin/oshfort\n";
        });
      openmp = pkgs.llvmPackages.openmp.override { ompdSupport = false; };
      # -liomp5 is Intel's name for the library; nixpkgs ships it as libomp.
      iomp5 = pkgs.runCommand "iomp5-compat" { } ''
        mkdir -p $out/lib
        ln -s ${openmp}/lib/libomp.so $out/lib/libiomp5.so
      '';

      vendored = pkgs.rustPlatform.importCargoLock {
        lockFile = ./Cargo.lock;
        allowBuiltinFetchGit = true;
      };

      # The vendored dependencies with one crate patched: proofman-starks-src,
      # ZisK's C++ STARK library (built by proofman-starks-lib-c's build.rs via
      # make), enables AVX-512 whenever the *build host* advertises it and
      # offers no override. Leave the detection empty; AVX2 stays.
      # importCargoLock records no per-file checksums, so edits are accepted;
      # the derivation keeps the name its .cargo/config.toml refers to.
      vendoredNoAvx512 = pkgs.runCommand "cargo-vendor-dir" { } ''
        cp -r ${vendored} $out
        chmod u+w $out
        rm $out/proofman-starks-src-*
        cp -rL ${vendored}/proofman-starks-src-* $out/
        chmod -R u+w $out/proofman-starks-src-*
        cd $out/proofman-starks-src-*
        substituteInPlace Makefile --replace-fail \
          "AVX512_SUPPORTED := \$(shell cat /proc/cpuinfo | grep -E 'avx512' -m 1)" \
          "AVX512_SUPPORTED :="
        substituteInPlace src/goldilocks/Makefile --replace-fail \
          "AVX512_SUPPORTED := \$(shell grep -m1 avx512f /proc/cpuinfo)" \
          "AVX512_SUPPORTED :="
      '';

      # enableAvx512 = false (default): a binary that runs on any x86-64-v3 host,
      # which a build on an AVX-512 machine would otherwise not (SIGILL at
      # startup). `.override { enableAvx512 = true; }` keeps upstream behaviour
      # (detect on the build host) for a binary that only runs where it was built.
      mkClient = { enableAvx512 ? false }: pkgs.rustPlatform.buildRustPackage {
        pname = "ethproofs-client";
        version = if self ? shortRev then self.shortRev else "dirty";
        src = lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [ ./Cargo.toml ./Cargo.lock ./build.rs ./src ];
        };
        cargoDeps = if enableAvx512 then vendored else vendoredNoAvx512;

        # Only the Monad adapter: the reth/ethrex/ziskethone clients are not
        # needed and pull in far more to compile.
        buildNoDefaultFeatures = true;
        buildFeatures = [ "monad" ];
        doCheck = false;

        nativeBuildInputs = [
          openmpi           # mpicc --showme:compile/link in the pil2-stark Makefile
        ] ++ (with pkgs; [
          pkg-config
          gnumake
          nasm
          protobuf          # protoc + google/protobuf includes for zisk-coordinator-api
          rustPlatform.bindgenHook   # mpi-sys
          autoconf automake libtool texinfo   # libffi-sys builds libffi with autotools
        ]);
        buildInputs = [
          openmpi
          openmp
          iomp5
        ] ++ (with pkgs; [
          libsodium
          gmp
          openssl
          nlohmann_json
          libffi
        ]);

        # No AVX-512 may remain outside blake3's runtime-dispatched code.
        postInstall = lib.optionalString (!enableAvx512) ''
          n=$(${pkgs.binutils-unwrapped}/bin/objdump -d -C --no-show-raw-insn $out/bin/ethproofs-client \
              | ${pkgs.gawk}/bin/awk '/^[0-9a-f]+ <.*>:$/ { fn=$0 } /zmm/ && fn !~ /_blake3_/ { c++ } END { print c+0 }')
          echo "AVX-512 instructions outside blake3: $n"
          test "$n" -eq 0
        '';

        meta.mainProgram = "ethproofs-client";
      };
    in
    {
      packages.${system} = rec {
        ethproofs-client = lib.makeOverridable mkClient { };
        ethproofs-client-avx512 = ethproofs-client.override { enableAvx512 = true; };
        default = ethproofs-client;
      };
    };
}
