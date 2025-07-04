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

    echo Main bot token: $(cat config/token)
    echo Dev bot token: $(cat config/token_dev)
    echo "Use 'run' to run the bot (alias of 'bundle exec ruby src/main.rb')"
  '';
}
