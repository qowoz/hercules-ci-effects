deps@{
  lib,
  nix,
  runCommand,
  openssh,
  writeText,
}:

let
  inherit (lib)
    escapeShellArg
    escapeShellArgs
    makeBinPath
    optionalString
    ;
in

{ destination
, useSubstitutes ? true
, ssh ? openssh
, sshOptions ? ""
, nix ? deps.nix
, nix-copy-closureOptions ? ""
, compress ? false
, compressClosure ? compress
, compressSession ? compress
, inheritVariables ? []
, buildOnDestination ? false
, destinationPkgs ? throw "hci-effects.ssh: buildOnDestination is true, but destinationPkgs is not set. Please set destinationPkgs to a Nixpkgs instance that is buildable on the destination."
}:

remoteCommands:

let

  commands = optionalString (inheritVariables != []) ''"$(declare -p ${escapeShellArgs inheritVariables});"''
    + lib.escapeShellArg remoteCommands';

  remoteCommands' =
    if buildOnDestination
    then destinationBuild remoteCommands
    else remoteCommands;

  # Turn a binary deployment into a source deployment.
  # type: string of bash statements -> string of bash statements
  #
  # Ideally we don't use and don't ask for destinationPkgs, but instead we
  # retrieve the derivation paths directly, without constructing an unnecessary
  # derivation (`file` below).
  # Such an approach would be possible with builtins.storePath, but that isn't
  # available in pure mode, yet(?).
  # See https://github.com/NixOS/nix/issues/5868#issuecomment-1757869475
  destinationBuild = commands:
    let
      file = destinationPkgs.writeText "remote-commands-after-build" commands;

      # Why `eval`? `source` would change the environment slightly.
    in ''
      (
        _call_ssh_script=$(nix-store -vr ${builtins.unsafeDiscardOutputDependency file.drvPath})
        eval "$(cat "$_call_ssh_script")"
        r=$?
        nix-store --delete "$_call_ssh_script" || echo "Failed to delete script file from store; ignoring."
        exit $r
      )
    '';

  # TODO (2022-01): Use upstream function: https://github.com/NixOS/nixpkgs/pull/123111
  writeDirectReferencesToFile = path: runCommand "runtime-references"
    {
      exportReferencesGraph = ["graph" path];
      inherit path;
    }
    ''
      touch ./references
      while read p; do
        read dummy
        read nrRefs
        if [[ $p == $path ]]; then
          for ((i = 0; i < nrRefs; i++)); do
            read ref;
            echo $ref >>./references
          done
        else
          for ((i = 0; i < nrRefs; i++)); do
            read ref;
          done
        fi
      done < graph
      sort ./references >$out
    '';

  referencesFile = writeDirectReferencesToFile (writeText "remote-commands" remoteCommands');
in ''(
  export PATH="${makeBinPath [nix ssh]}:$PATH"
  _call_ssh_references="''${ssh_copy_paths:-}''${ssh_copy_paths:+ }$(cat ${referencesFile})"
  if [[ -n "$_call_ssh_references" ]]; then
    NIX_SSHOPTS="${sshOptions}" nix-copy-closure ${nix-copy-closureOptions} ${optionalString useSubstitutes "--use-substitutes"} ${optionalString compressClosure "--gzip"} --to ${destination} $_call_ssh_references
  fi
  ssh ${optionalString compressSession "-C"} ${sshOptions} ${destination} -- ${commands})''
