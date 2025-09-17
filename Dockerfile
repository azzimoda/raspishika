FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        libfontconfig1 \
        libfreetype6 \
        libgmp-dev \
        libharfbuzz-dev \
        libxml2-dev \
        libxslt-dev \
        ca-certificates \
        nodejs \
        npm \
        # Playwright dependencies
        libasound2 \
        libatk-bridge2.0-0 \
        libatk1.0-0 \
        libatspi2.0-0 \
        libcairo2 \
        libcups2 \
        libdbus-1-3 \
        libgbm1 \
        libnspr4 \
        libnss3 \
        libpango-1.0-0 \
        libx11-6 \
        libxcb1 \
        libxcomposite1 \
        libxdamage1 \
        libxext6 \
        libxfixes3 \
        libxkbcommon0 \
        libxrandr2 \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Set environment variables
ENV GEM_HOME=/app/.gems \
    GEM_PATH=/app/.gems \
    BUNDLE_PATH=/app/.gems \
    PATH="/app/.gems/bin:$PATH" \
    PLAYWRIGHT_BROWSERS_PATH=/app/.playwright-browsers

# Copy Gemfiles and install dependencies
COPY Gemfile Gemfile.lock ./

RUN gem update --system && \
    gem install bundler -v '~> 2.6' && \
    bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs=4 --retry=3

# Copy application code
COPY . .

# Install Playwright JS client and chromium
RUN npm install playwright && \
    npx playwright install chromium


# Application entrypoint
ENTRYPOINT ["bundle", "exec", "ruby"]
CMD ["src/main.rb"]
