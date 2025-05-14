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
    fonts-freefont-ttf \
    libnss3 \
    libfreetype6 \
    libharfbuzz-dev \
    ca-certificates \
    nodejs \
    npm \
    chromium \
    chromium-driver \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy Gemfiles and install dependencies
COPY Gemfile Gemfile.lock ./

RUN gem update --system && \
    gem install bundler -v '~> 2.6.8' && \
    bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs=4 --retry=3

# Copy application code
COPY . .

# Install Playwright JS client without installing browsers
RUN PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install playwright && \
    npx playwright install chromium

# Set environment variables
ENV GEM_HOME=/app/vendor/bundle \
    GEM_PATH=/app/vendor/bundle \
    PATH="/app/vendor/bundle/bin:$PATH" \
    CACHE=10 \
    CHROMEDRIVER_PATH=/usr/bin/chromedriver \
    CHROME_PATH=/usr/bin/chromium \
    CHROME_BIN=/usr/bin/chromium \
    DISPLAY=:99

# Create necessary directories
RUN mkdir -p data data/cache data/debug

# Application entrypoint
CMD ["bundle", "exec", "ruby", "src/main.rb"]
