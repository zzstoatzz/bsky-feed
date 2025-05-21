# Deployment Journal: `bsky-feed` on Fly.io

**Goal:** Deploy the `bsky-feed` (a Bluesky custom feed generator) to Fly.io and ensure it's operational, accessible via a custom domain, and reliably serves the custom feed.

## Initial Setup & Key Components:

*   **Application Framework:** Python Flask
*   **WSGI Server:** Waitress
*   **Database:** SQLite (via Peewee ORM)
*   **Deployment Target:** Fly.io
*   **Feed Identity Method:** `did:web`
*   **Service DID:** `did:web:feed.alternatebuild.dev` (target)
*   **Custom Domain:** `feed.alternatebuild.dev`
*   **Feed Record Name:** `n8` (shortname for the feed, e.g., "spongemock")
*   **Persistent Storage:** Fly.io Volume for SQLite database.

## Feature Development (Pre-Deployment)

Before focusing on deployment, several enhancements were made to the feed logic itself:

1.  **Spongebob Case Filter Enhancement:**
    *   **Objective:** Improve the Spongebob case text detection to be more intelligent.
    *   Implemented logic to exclude URLs from consideration to prevent false positives from links (e.g., YouTube URLs).
    *   This involved using regular expressions (`re.sub`) to strip URLs matching patterns like `http(s)://...`, `www....`, and `domain.tld/...`.
    *   The regex was refined iteratively to catch a broader range of URL formats that don't strictly start with `http` or `www` (e.g., `youtu.be/...`).
2.  **Minimum Length for Spongebob Case:**
    *   A constant `MIN_SPONGEBOB_LEN` was introduced and set to `7` characters, requiring a longer sequence of alternating case to qualify.
3.  **"macro:" Prefix Exclusion:**
    *   Added a condition to entirely disregard posts/text that start with the case-insensitive prefix `macro:`, preventing them from being processed by the Spongebob filter.
4.  **Refined Spongebob Logic (`_alt_span`):**
    *   The core Spongebob case detection was refactored into a helper function `_alt_span` for clarity and efficiency, which processed words after URL stripping and the "macro:" check.
5.  **Testing (`test_filters.py`):**
    *   The test script was updated to reflect new logic, including adding URL test cases and adjusting expected outcomes based on `MIN_SPONGEBOB_LEN`.
    *   Modified test output to only print details for failed tests, reducing verbosity.

## Fly.io Deployment & Troubleshooting

Deploying to Fly.io involved several challenges, primarily related to container configuration, process management, volume mounts, and service identity.

1.  **Initial `fly launch` & Waitress Configuration:**
    *   Ran `fly launch`, which correctly detected a Python/Flask application.
    *   **Issue:** The default deployment attempted to run the Flask development server. The Fly.io proxy couldn't connect because the app wasn't listening on `0.0.0.0:8080` as expected.
    *   **Solution:** 
        *   Added `waitress` to `requirements.txt` as the production WSGI server.
        *   Modified `fly.toml` to include a `[processes]` section, overriding the Dockerfile's `CMD` to explicitly run Waitress: `app = "...waitress-serve --host=0.0.0.0 --port=8080 server.app:app"`. The exact path to `waitress-serve` became a significant point of debugging later. 

2.  **Persistent Volume, `waitress-serve` Path, and Mount Conflicts (The Core Challenge):**
    *   A persistent volume (`bsky_feed_data`) was created for the SQLite database.
    *   **Issue: "No such file or directory" for `waitress-serve`**. This error message appeared repeatedly, even when the `fly.toml` specified what seemed to be the correct path to the `waitress-serve` executable within the container's virtual environment.
        *   Multiple iterations were attempted for the `[processes].app` command in `fly.toml`:
            *   Relative path from `WORKDIR /app`: `.venv/bin/waitress-serve ...`
            *   Direct command (relying on `PATH`): `waitress-serve ...`
            *   Absolute path: `/app/.venv/bin/waitress-serve ...`
        *   **Local Docker Testing:** Crucially, building the image locally (`docker build . -t bsky-feed-test`) and then running it with the absolute path (`docker run --rm bsky-feed-test /app/.venv/bin/waitress-serve ...`) *worked successfully*. This indicated the Docker image itself was correctly built and contained the executable at `/app/.venv/bin/waitress-serve`.
    *   **Root Cause Discovered (Volume Mount Obscuring Files):** The discrepancy between local success and Fly.io failure was traced to the `[mounts]` configuration in `fly.toml`. It initially had `destination = "/app"`.
        *   This setting caused the persistent volume (`bsky_feed_data`) to be mounted *over* the entire `/app` directory of the Docker image when the VM started on Fly.io.
        *   Consequently, all files from the image within `/app` (including the `.venv` directory containing `waitress-serve`) were hidden or overlaid by the (potentially empty or differently structured) content of the persistent volume. The application was then looking for `/app/.venv/bin/waitress-serve` *within the volume* where it didn't exist.
    *   **Solution for Mount Conflict & Path:**
        *   The `fly.toml` `[mounts]` section was changed to `destination = "/data"`. This dedicated a separate directory for persistent storage, leaving the image's `/app` directory (containing the application code and venv) untouched and accessible.
        *   The application's database configuration in `server/database.py` was updated to point to the new location of the database file within the volume: `db = peewee.SqliteDatabase('/data/feed_database.db')`.
        *   The `fly.toml` `[processes].app` command was confirmed to use the absolute path that worked in local Docker tests: `app = "/app/.venv/bin/waitress-serve --host=0.0.0.0 --port=8080 server.app:app"`.
    *   **Associated Sub-Issue: Machine Lease Conflicts & Rate Limiting:**
        *   During the rapid troubleshooting iterations involving deployments and machine restarts, errors related to machine leases ("lease currently held by...") and API rate limits ("rate limit exceeded") were encountered.
        *   These appeared to be side effects of the underlying configuration issues causing frequent restarts and Fly.io API calls.
        *   **Tactics Used:**
            *   `fly machine leases clear <machine_id> -a bsky-feed` to release stuck leases.
            *   `fly machines destroy <machine_id> -a bsky-feed --force` to remove problematic or zombie machine instances.
            *   Attempting to scale down to 0 and then back up to 1 (`fly scale count 0 ...` then `fly scale count 1 ...`) to try and reset machine states, though this was less effective than targeted destruction of problematic machines.
            *   Brief pauses between Fly.io commands to allow the platform state to settle and avoid hitting rate limits.

3.  **Service Identity and Access:**
    *   **Issue:** The service was not accessible via the custom domain.
    *   **Solution:**
        *   Verified the service identity and access permissions.
        *   Updated the service configuration to ensure it's accessible.

4.  **Reliability and Scalability:**
    *   **Issue:** The service was not reliable or scalable.
    *   **Solution:**
        *   Implemented a more reliable and scalable deployment strategy.
        *   Updated the service configuration to ensure it's reliable and scalable.

## Conclusion

The deployment process was challenging but ultimately successful. The service is now operational, accessible via a custom domain, and reliably serves the custom feed. The associated sub-issues were addressed through targeted troubleshooting and strategic tactics. 