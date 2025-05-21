# run the feed generator server with Waitress
run:
    @echo "Starting server with Waitress on http://0.0.0.0:8080..."
    uv run waitress-serve --listen=0.0.0.0:8080 spongemock_bsky_feed_generator.server.app:app

# run the tests
test:
    @echo "Running tests with pytest..."
    uv run pytest 

# publish the feed
publish:
    @echo "Publishing feed..."
    uv run python src/spongemock_bsky_feed_generator/publish_feed.py
