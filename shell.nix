{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    bash
    curl
    git

    ruby_3_4
    bundler

    nodejs_20
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

    export CACHE=10

    if [ -f .token ]; then
      export TELEGRAM_BOT_TOKEN=$(cat .token)
    else
      echo "Warning: .token file not found. Set TELEGRAM_BOT_TOKEN manually."
    fi

    if [ -f .token_dev ]; then
      export DEV_BOT_TOKEN=$(cat .token_dev)
    else
      echo "Warning: .token_dev file not found. Set DEV_BOT_TOKEN manually."
    fi

    mkdir -p data data/cache data/debug

    if [ ! -d "$GEM_HOME" ]; then
      gem install bundler -v '~> 2.6'
      bundle config set --local path "$GEM_HOME"
    fi
    bundle install --jobs=4 --retry=3

    if [ ! -d ".playwright-install-flag" ]; then
      echo "Installing Playwright browsers..."
      PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install playwright && \
        npx playwright install chromium && \
        mkdir .playwright-install-flag
    fi

    alias run='bundle exec ruby src/main.rb'

    echo TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
    echo DEV_BOT_TOKEN=$DEV_BOT_TOKEN
    echo "Use 'run' to run the bot (alias of 'bundle exec ruby src/main.rb')"
  '';
}
