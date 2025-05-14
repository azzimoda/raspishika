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
    export GEM_HOME=$PWD/.gems
    export GEM_PATH=$GEM_HOME
    export BUNDLE_PATH=$GEM_HOME
    export PATH=$PATH:$GEM_PATH

    export CROMEDRIVER_PATH=${pkgs.chromedriver}/bin/chromedriver
    export CHROME_PATH=${pkgs.chromium}/bin/chromium
    export CHROME_BIN=${pkgs.chromium}/bin/chromium
    export DISPLAY=:99

    export CACHE=10

    if [ -f .token ]; then
      export TELEGRAM_BOT_TOKEN=$(cat .token)
    else
      echo "Warning: .token file not found. Set TELEGRAM_BOT_TOKEN manually."
    fi

    mkdir -p data data/cache data/debug

    if [ ! -d "$GEM_HOME" ]; then
      gem install bundler -v '~> 2.6'
      bundle config set --local path "$GEM_HOME"
    fi
    bundle install --jobs=4 --retry=3

    echo TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
    echo "Use bundle exec ruby src/main.rb to run the bot"
  '';
}
