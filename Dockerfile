# Use Alpine-based Ruby image
FROM ruby:3.4.3-alpine

# Install system dependencies
RUN apk update && \
    apk add --no-cache \
    chromium \
    chromium-chromedriver \
    git \
    curl \
    libxml2-dev \
    libxslt-dev \
    gmp-dev \
    ttf-freefont \
    nss \
    freetype \
    harfbuzz \
    ca-certificates && \
    apk add --no-cache --virtual .build-deps \
    build-base \
    ruby-dev

# Set working directory
WORKDIR /app

# Copy Gemfiles and install dependencies
COPY Gemfile Gemfile.lock ./

RUN gem update --system && \
    gem install bundler -v '~> 2.6' && \
    bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs=4 --retry=3

# Copy application code
COPY . .

# Environment variables
ENV GEM_HOME=/app/vendor/bundle \
    GEM_PATH=/app/vendor/bundle \
    PATH="/app/vendor/bundle/bin:$PATH" \
    CACHE=10 \
    CHROMEDRIVER_PATH=/usr/bin/chromedriver \
    CHROME_PATH=/usr/bin/chromium-browser \
    CHROME_BIN=/usr/bin/chromium-browser \
    DISPLAY=:99

# Create necessary directories
RUN mkdir -p data data/cache data/debug

# Cleanup build dependencies
RUN apk del .build-deps

# Application entrypoint
CMD ["bundle", "exec", "ruby", "src/main.rb"]
