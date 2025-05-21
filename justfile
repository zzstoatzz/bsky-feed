# run the feed generator server with Waitress
run:
    @echo "Starting server with Waitress on http://0.0.0.0:8080..."
    uv run waitress-serve --listen=0.0.0.0:8080 bsky_feed_generator.server.app:app

# run the tests
test:
    @echo "Running tests with pytest..."
    uv run pytest 

# publish the feed
publish:
    @echo "Publishing feed..."
    PYTHONPATH=. uv run python src/bsky_feed_generator/publish_feed.py


# run the docker image with .env file
docker-test:
    @echo "Running Docker image bsky-feed-generator with .env file..."
    docker build . -t bsky-feed-generator
    docker run --rm --env-file .env bsky-feed-generator

deploy:
    fly deploy