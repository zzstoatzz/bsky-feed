from waitress import serve

from bsky_feed_generator.server.app import app
from bsky_feed_generator.server.config import settings
from bsky_feed_generator.server.logger import logger


def main():
    logger.critical("APPLICATION RUNSERVER MAIN HAS STARTED - VERSION 1")
    # The database module now handles its own directory creation if needed.
    # Run the server
    serve(app, host=str(settings.LISTEN_HOST), port=settings.LISTEN_PORT)


if __name__ == "__main__":
    main()
