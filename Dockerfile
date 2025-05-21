FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

WORKDIR /app

ENV PYTHONPATH="/app"

RUN apt-get update && \
    apt-get install -y git curl --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

COPY . /app

RUN uv sync

EXPOSE 8080

CMD ["uv", "run", "bsky_feed_generator"]
