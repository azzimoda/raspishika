{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    bash
    curl
    git
    ruby_3_2
    chromium
    chromedriver
    # google-chrome
  ];

  shellHook = ''
    export GEM_HOME=$(pwd)/.gem
    export GEM_PATH=$GEM_HOME
    export PATH=$PATH:$GEM_PATH

    which ruby
    which bundle
    echo GEM_HOME $GEM_HOME
    echo "Welcome to the Nix environment for $(pwd)!"
  '';
}
