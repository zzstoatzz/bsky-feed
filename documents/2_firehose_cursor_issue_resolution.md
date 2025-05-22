# Resolving the Firehose Feed Stalling Issue

This document outlines the troubleshooting process, root cause analysis, and resolution for an issue where the Bluesky feed generator, deployed on Fly.io, would appear to stall or fall significantly behind after processing a few initial posts.

## 1. Problem Statement

The primary symptoms were:
*   The application would process a small number of posts immediately after deployment.
*   Subsequently, it would either stop processing new posts or fall progressively behind real-time.
*   Old posts, often from around the time of the last deployment, would trickle in, suggesting it was re-processing a backlog.
*   Fly.io health checks for the web server would consistently pass.
*   The issue persisted despite ensuring `min_machines_running = 1` and configuring `auto_stop_machines = "off"`.

## 2. Initial Troubleshooting & Misconceptions

Our initial investigation explored several hypotheses:

*   **Fly.io Auto-Stop Behavior:** We initially suspected Fly.io's `auto_stop_machines` feature was prematurely stopping the instance. We adjusted `fly.toml` to ensure `min_machines_running = 1` and explicitly set `auto_stop_machines = "off"`. While good practice, this did not resolve the core stalling issue.
*   **Errors in Custom Filter Logic:** We hypothesized that an unhandled exception within the `CUSTOM_FILTER_FUNCTION` might be silently killing the firehose processing thread.
    *   We enhanced error handling in `data_filter.py` to re-raise exceptions from the custom filter.
    *   We added exception catching and detailed logging (with tracebacks) in `data_stream.py` around the `operations_callback`.
    *   However, local tests (`just docker-test`) with the same configuration (including the custom filter and `LOG_LEVEL=DEBUG`) worked flawlessly, indicating the filter logic itself was likely not the primary cause of stalling on Fly.io.
*   **Environment Variable Discrepancies:**
    *   We found `LOG_LEVEL` was not being correctly set on Fly.io, hindering detailed debugging. This was resolved by setting it as a Fly.io secret.
    *   The `CUSTOM_FILTER_FUNCTION` format (`example_custom_filters:spongebob_filter`) was confirmed to be correctly handled by Pydantic's `ImportString`.

## 3. Key Discovery: Database Table & Cursor Issues

The investigation then focused on the persistence layer:

*   **Missing `subscription_state` Table:** Initial attempts to query the SQLite database on Fly.io suggested the `subscription_state` table (crucial for storing the firehose cursor) was not being created.
*   **Ensuring Table Creation:** We modified `src/bsky_feed_generator/server/database.py` to unconditionally call `db.create_tables([Post, SubscriptionState], safe=True)` upon module import, ensuring the tables are created if they don't exist.
*   **Database Path Confusion:** A brief period of confusion arose from checking an incorrect database path (`/data/my_feed.db`) via SSH. The `fly.toml` correctly specified `DATABASE_URI = "/data/feed_database.db"`. Once this was clarified, we confirmed the tables *were* being created.
*   **Existing Cursor Value:** We found a cursor value (e.g., `9447863000`) in the `subscriptionstate` table.

## 4. Root Cause Analysis: Flawed Cursor Logic in `data_stream.py`

The presence of a cursor, combined with the "old posts trickling in" symptom, pointed to a subtle but critical flaw in how the firehose cursor was initialized and managed in `src/bsky_feed_generator/server/data_stream.py`:

*   **Mismatched Initialization on First Run (No Existing State):**
    1.  If `SubscriptionState.get_or_none(...)` returned `None` (i.e., no cursor in the DB for the service):
        *   The `FirehoseSubscribeReposClient` was initialized with `params = None`. This correctly tells the ATProto library to request messages starting from the `head` (the latest available data from the firehose).
        *   **Crucially, immediately after this, the code executed `SubscriptionState.create(service=name, cursor=0)`.** This wrote `cursor=0` to the database.
    2.  This created an immediate desynchronization:
        *   The application was connected to the firehose and receiving *current/latest* data.
        *   But the database recorded its official starting point as `cursor=0` (which implies "start from the very beginning of all firehose history").

*   **Consequences of the Flaw:**
    *   **Scenario 1: Restart Before First Cursor Save:** If the application started fresh (no DB state), wrote `cursor=0` to the DB, and then restarted *before* the first actual `commit.seq` from a message was saved (which happened every 1000 messages):
        *   On restart, it would read `cursor=0` from the database.
        *   It would then instruct the firehose client to fetch messages starting from `cursor=0`.
        *   This would lead to the app attempting to process the *entire history* of the firehose, causing it to fall massively behind and seemingly stall while churning through extremely old data.
    *   **Scenario 2: Restart After First "Real" Cursor Save:**
        *   If the app started fresh, wrote `cursor=0` (while actually listening from `head`), then processed 1000 messages, it would save the then-current `commit.seq` (e.g., `9447863000`) to the database, overwriting the `0`.
        *   If the app restarted *after* this point, it would correctly use `9447863000`. However, this `9447863000` might correspond to a point in time *after* the app had already processed some initial messages during its first run (when it was listening from `head` but before this first save). This could result in a small gap of unprocessed posts. This also explained why "old posts from the time of deployment" would appear if that's when such a cursor got written.

## 5. The Fix: Corrected Cursor Handling

The solution involved modifying `src/bsky_feed_generator/server/data_stream.py`:

1.  **Removed Problematic Initialization:** The line `SubscriptionState.create(service=name, cursor=0)` that was executed when no state was found was removed.
2.  **Start from Head if No State:** If no existing state is found in the database, the `FirehoseSubscribeReposClient` is initialized with `params=None`, correctly starting the stream from the `head`. The log message was updated to reflect this: `"DATA_STREAM: No existing state found for service '{name}'. Will start with no cursor (from head)."`
3.  **Upsert Logic for Cursor Saving:** The logic in `on_message_handler` for saving the cursor (every 1000 messages) was changed to an "upsert" (update or insert):
    ```python
    SubscriptionState.insert(service=name, cursor=commit.seq).on_conflict(
        conflict_target=(SubscriptionState.service,),  # service is unique
        action='UPDATE',
        update={SubscriptionState.cursor: commit.seq}
    ).execute()
    ```
    This ensures that:
    *   If no record exists for the service, one is created with the current `commit.seq`.
    *   If a record *does* exist, its `cursor` field is updated with the current `commit.seq`.

4.  **Post-Fix Procedure for Clean Start:**
    *   To ensure a truly clean start with the new logic, we manually deleted the existing cursor entry from the `subscriptionstate` table in the Fly.io database using an SSH command.
    *   The corrected code was then deployed.
    *   On its first run, the application found no existing state (as intended), started fetching from `head`, and the first time it saved a cursor, it correctly created a new record with a genuinely current `commit.seq`.

## 6. Lessons Learned

This troubleshooting journey provided several important lessons:

*   **Cursor Integrity is Paramount:** For any stream processing application, the logic for initializing, saving, and restoring the cursor (or offset/sequence number) is critical. Discrepancies can lead to data loss, reprocessing, or the appearance of stalling.
*   **Database State Must Reflect Actual Intent:** Persisted state (like a cursor in a database) must accurately reflect the application's true operational point. Writing a "default" or "initial" cursor (like `0`) that doesn't match the actual stream starting point (like `head`) is a significant source of bugs.
*   **Atomic Operations for State Management:** Using database features like "upsert" (e.g., `INSERT ... ON CONFLICT ... DO UPDATE`) for saving state like cursors is robust, simplifies logic, and helps ensure atomicity.
*   **Test Edge Cases for Initialization and Recovery:** Thoroughly test scenarios like:
    *   Application startup with a completely empty/new database.
    *   Application restart after a crash *before* the first cursor save.
    *   Application restart after a crash *after* one or more cursor saves.
*   **The Power of Detailed and Accessible Logging:** `LOG_LEVEL=DEBUG` and ensuring logs were correctly configured and accessible on the deployment platform were invaluable. Clear log messages indicating the current state (e.g., "starting from head" vs. "using existing cursor") are essential.
*   **Verify Environmental Assumptions:** When interacting with external services or environments (like a database on a mounted volume in Fly.io), double-check assumptions like paths, connection strings, and permissions. Our initial confusion over the database filename highlights this.
*   **Iterative Problem Solving:** Complex issues often require peeling back layers. What initially seemed like a platform issue (Fly.io auto-stop) evolved into an application logic error deep within the cursor management.

By addressing the cursor initialization and saving logic, the application now correctly tracks its position in the firehose, processes data in real-time, and recovers reliably from restarts. 