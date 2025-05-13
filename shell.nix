{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    bash
    curl
    git
    ruby_3_4
    bundler
    chromium
    chromedriver
    libxml2.dev
    libxslt.dev
    gmp.dev
    freetype
    harfbuzz
    fontconfig
    cacert
  ];

  shellHook = ''
    export GEM_HOME=$(pwd)/.gem
    export GEM_PATH=$GEM_HOME
    export PATH=$PATH:$GEM_PATH

    export CACHE=10 # Default cache expiration time
    export CROMEDRIVER_PATH=${pkgs.chromedriver}/bin/chormedriver
    export CHROME_PATH=${pkgs.chromium}/bin/chromium
    export CHROME_BIN=${pkgs.chromium}/bin/chromium
    export DISPLAY=:99

    if [ -f .token ]; then
      export TELEGRAM_BOT_TOKEN=$(cat .token)
    else
      echo "Warning: .token file not found. Set TELEGRAM_BOT_TOKEN manually."
    fi

    mkdir -p data data/cache data/debug

    if [ ! -d .gem ]; then
      gem install bundler -v '~> 2.6'
      bundle config set --local path '.gem'
      bundle install --jobs=4 --retry=3
    fi

    echo TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
    echo "Welcome to the Nix environment for $(pwd)!"
  '';
}
