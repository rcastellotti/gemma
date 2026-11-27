{
  description = "GEMMA3`";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }: {
    devShells = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        default = pkgs.mkShell {
          packages = [
            pkgs.zig
            pkgs.fish
          ];
          shellHook = ''
            if [[ $- == *i* ]]; then
              exec fish
            fi
          '';
        };
      }
    );
  };
}
