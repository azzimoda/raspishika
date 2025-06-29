FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    libxml2-dev \
    libxslt-dev \
    libgmp-dev \
    libfreetype6 \
    libharfbuzz-dev \
    libfontconfig1 \
    ca-certificates \
    nodejs \
    npm \
    # Playwright dependencies
    libdbus-1-3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libxcb1 \
    libxkbcommon0 \
    libatspi2.0-0 \
    libx11-6 \
    libxcomposite1 \
    libxdamage1 \
    libxext6 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libcairo2 \
    libpango-1.0-0 \
    libasound2 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Set environment variables
ENV GEM_HOME=/app/.gems \
    GEM_PATH=/app/.gems \
    BUNDLE_PATH=/app/.gems \
    PATH="/app/.gems/bin:$PATH" \
    PLAYWRIGHT_BROWSERS_PATH=/app/.playwright-browsers

# Create necessary directories
RUN mkdir -p data data/cache data/debug

# Copy Gemfiles and install dependencies
COPY Gemfile Gemfile.lock ./

RUN gem update --system && \
    gem install bundler -v '~> 2.6' && \
    bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs=4 --retry=3

# Copy application code
COPY . .

# Install Playwright JS client and chromium
RUN PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install playwright && \
    npx playwright install chromium && \
    npx playwright install-deps

# Application entrypoint
ENTRYPOINT [ "bundle", "exec", "ruby", "src/main.rb" ]
CMD []
