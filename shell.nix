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

    export TELEGRAM_BOT_TOKEN=$(cat .token)

    which ruby
    echo GEM_HOME=$GEM_HOME
    echo TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
    echo "Welcome to the Nix environment for $(pwd)!"
  '';
}
