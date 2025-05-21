FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

WORKDIR /app

# astral-sh/uv images don't have git by default, needed for git dependencies
# and other common tools that might be useful.
RUN apt-get update && \
    apt-get install -y git curl --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Copy the entire application context
COPY . /app

# Install dependencies using uv
# This assumes your pyproject.toml is set up for uv and includes all dependencies.
RUN uv sync

# Expose the port the app runs on
EXPOSE 8080

# Command to run the application
# This uses the script defined in pyproject.toml
CMD ["uv", "run", "spongemock_bsky_feed_generator"]
