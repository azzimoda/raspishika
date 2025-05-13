# Use a lightweight Ruby base image
FROM ruby:3.4.3-slim

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    chromium \
    chromium-driver \
    git \
    curl \
    build-essential \
    ruby-dev \
    pkg-config \
    libxml2-dev \
    libxslt-dev \
    libgmp-dev && \
    rm -rf /var/lib/apt/lists/*

# Set the working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock first to leverage Docker cache
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies
RUN gem update --system && \
    gem install bundler  -v '~> 2.6' && \
    bundle config set --local path 'vendor/bundle' && \
    bundle install --jobs=4 --retry=3

# Copy the rest of the application code
COPY . .

# Set environment variables
ENV GEM_HOME=/app/vendor/bundle \
    GEM_PATH=/app/vendor/bundle \
    PATH="/app/vendor/bundle/bin:$PATH" \
    CACHE=10

# Create necessary directories
RUN mkdir -p .data .cache .debug

# Clean up build dependencies (optional)
RUN apt-get purge -y --auto-remove build-essential ruby-dev pkg-config

# Command to run the application
CMD ["bundle", "exec", "ruby", "src/main.rb"]
