from waitress import serve

from spongemock_bsky_feed_generator.server.app import app
from spongemock_bsky_feed_generator.server.config import settings


def main():
    # The database module now handles its own directory creation if needed.
    # Run the server
    serve(app, host=str(settings.LISTEN_HOST), port=settings.LISTEN_PORT)


if __name__ == "__main__":
    main()
