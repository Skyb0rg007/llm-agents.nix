{
  lib,
  flake,
  stdenv,
  platformSource,
  wrapBuddy,
  buildFHSEnv,
  writeShellScript,
  bubblewrap,
  socat,
  gcc-unwrapped,
  zlib,
  cacert,
  versionCheckHook,
  versionCheckHomeHook,
  mkUpdater,
}:

let
  source = platformSource {
    hashesFile = ./hashes.json;
    # Upstream also publishes darwin and windows builds, but only linux-x64 is
    # downloadable from a public, version-pinned URL.
    platforms = {
      x86_64-linux = "linux-x64";
    };
    urlTemplate = "https://downloads.claude.ai/claude-science/{version}/{platform}";
  };

  meta = with lib; {
    description = "Run Claude on your research data locally, with a web UI for notebooks, analysis and scientific workflows";
    homepage = "https://claude.com/product/claude-science";
    changelog = "https://claude.com/docs/claude-science/changelog";
    license = flake.lib.licenses.unfree;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    maintainers = with maintainers; [ skyesoss ];
    mainProgram = "claude-science";
    platforms = source.platforms;
  };

  unwrapped = stdenv.mkDerivation {
    pname = "claude-science-unwrapped";
    inherit (source) version src;

    dontUnpack = true;

    nativeBuildInputs = [ wrapBuddy ];

    dontStrip = true; # bun-compiled: stripping corrupts the embedded payload

    installPhase = ''
      runHook preInstall

      install -Dm755 $src $out/bin/claude-science

      runHook postInstall
    '';

    doInstallCheck = true;
    nativeInstallCheckInputs = [
      versionCheckHook
      versionCheckHomeHook
    ];

    inherit meta;
  };

  # The daemon self-updates by default, which cannot work from the Nix store.
  # Only `serve` accepts --no-auto-update (every other subcommand rejects
  # unknown flags), so inject it for that subcommand alone.
  launcher = writeShellScript "claude-science" ''
    if [ "''${1-}" = serve ]; then
      shift
      set -- serve --no-auto-update "$@"
    fi
    exec ${unwrapped}/bin/claude-science "$@"
  '';
in
# The daemon installs micromamba and conda-forge environments (python, R, the
# bundled MCP servers) at runtime; those are generic-linux binaries that need
# an FHS loader. The analysis sandbox re-binds /usr, /lib, /lib64 and /nix
# from this environment, so sandboxed code cells see the same loader.
buildFHSEnv {
  pname = "claude-science";
  inherit (source) version;
  inherit meta;

  targetPkgs = _: [
    # The analysis sandbox refuses to start without these on PATH.
    bubblewrap
    socat
    gcc-unwrapped.lib
    zlib
  ];

  runScript = launcher;

  # buildFHSEnv links /etc/ssl/certs to the host's /etc via /.host-etc, which
  # the analysis sandbox does not bind, so micromamba finds no CA bundle there.
  # Bind the resolved host bundle (custom CAs included) at another path it
  # probes, falling back to nixpkgs' bundle on hosts without one.
  extraBwrapArgs = [
    ''--ro-bind "$(readlink -e /etc/ssl/certs/ca-certificates.crt || echo ${cacert}/etc/ssl/certs/ca-bundle.crt)" /etc/ssl/cert.pem''
  ];

  passthru = {
    inherit unwrapped;
    category = "AI Assistants";
    updater = mkUpdater {
      kind = "manifest-checksums";
      versionSource = {
        type = "text";
        url = "https://downloads.claude.ai/claude-science/latest/manifest.json";
        regex = ''"version": *"([^"]+)"'';
      };
      manifestUrl = "https://downloads.claude.ai/claude-science/{version}/manifest.json";
      checksumPath = "sha256.{platform}";
      platforms = source.updater.platforms;
    };
  };
}
