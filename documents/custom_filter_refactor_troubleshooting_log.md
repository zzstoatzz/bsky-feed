# Troubleshooting Log: Custom Filter Refactoring

This document outlines the troubleshooting steps taken to resolve test failures encountered during the refactoring of the post-filtering logic in the Bsky Feed Generator. The goal was to make the filtering configurable via a user-supplied Python function path.

## Initial Problem

After refactoring `data_filter.py` to use a custom filter function specified by `settings.CUSTOM_FILTER_FUNCTION` and updating `tests/test_filters.py`, two main categories of tests were failing:

1.  **`test_custom_spongebob_filter_positive_cases`**: These tests, which used the example Spongebob filter, were failing because the `Post.create` mock (`mock_create`) was not being called, indicating the Spongebob filter was (incorrectly) excluding posts it should have included.
2.  **`test_custom_filter_error_handling`**: This test, designed to ensure that exceptions raised by a custom filter were caught and logged, was failing because the expected error message was not found in `caplog.text`.

## Debugging Steps & Discoveries

The debugging process involved several iterations of adding diagnostic `print` statements and analyzing `pytest` output with `caplog`.

### 1. Verifying Filter Execution and Log Capture

*   **Initial Check**: Added `logger.debug` statements within the `example_custom_filters.spongebob_filter` and `_alt_span` helper.
*   **Observation**: No debug logs from `example_custom_filters` were appearing in the `pytest -s` output for the failing positive Spongebob cases, even when `caplog.set_level(logging.DEBUG, logger="example_custom_filters")` was used in the test. This suggested either the filter wasn't being called or its logs weren't being captured as expected.
*   **`data_filter.py` Logs**: Similar checks were done for logs in `data_filter.py` when the custom filter was supposed to be called or when it errored.

### 2. Tracing Execution Flow in `operations_callback`

*   **Diagnostic `print` statements** were added to `operations_callback` in `data_filter.py` to trace the execution path.
*   **Key Finding 1**: A `print` statement placed *immediately before* the `try...except` block that calls `settings.CUSTOM_FILTER_FUNCTION(...)` was not being executed for the failing tests.
    ```python
    # data_filter.py
    if settings.CUSTOM_FILTER_FUNCTION:
        print(f"DEBUG data_filter: Attempting to call custom filter...") # THIS WAS NOT PRINTING
        try:
            if settings.CUSTOM_FILTER_FUNCTION(record, created_post):
                post_passes_custom_filter = True
    ```
*   This indicated that the condition `if settings.CUSTOM_FILTER_FUNCTION:` was evaluating to `False`, or an earlier `continue` statement was being hit.

### 3. Investigating `should_ignore_post`

*   A `print` statement was added to show the result of `should_ignore_post(created_post)` right before its conditional `continue`.
*   **Key Finding 2**: `should_ignore_post` was correctly returning `False` for the test cases, meaning it was *not* the cause of the early `continue`.

### 4. The `monkeypatch` Target and Settings Instance Mismatch (The Root Cause)

*   With `should_ignore_post` ruled out, the focus shifted to why `if settings.CUSTOM_FILTER_FUNCTION:` in `data_filter.py` would be `False` when the tests were explicitly setting it using `monkeypatch.setattr(config.settings, "CUSTOM_FILTER_FUNCTION", ...)`.
*   **Hypothesis**: The `settings` object imported and used by `data_filter.py` (`from bsky_feed_generator.server.config import settings`) was a *different instance* than the `config.settings` object being patched in `tests/test_filters.py` (`from src.bsky_feed_generator.server import config`).
*   **Verification**: `print(id(settings))` and `print(id(settings.CUSTOM_FILTER_FUNCTION))` were added in both the test files (after patching) and in `data_filter.py` (before the `if settings.CUSTOM_FILTER_FUNCTION:` check).
    *   **Test Output (Spongebob Test - Simplified):**
        ```
        DEBUG TEST (spongebob): ID of settings object in test: 4835606144
        DEBUG TEST (spongebob): CUSTOM_FILTER_FUNCTION in test: <function spongebob_filter ...>
        DEBUG TEST (spongebob): ID of CUSTOM_FILTER_FUNCTION in test: 4694541152
        ```
    *   **`data_filter.py` Output (during Spongebob Test):**
        ```
        DEBUG data_filter: ID of settings object in data_filter: 4692798240
        DEBUG data_filter: CUSTOM_FILTER_FUNCTION in data_filter before check: None
        DEBUG data_filter: ID of CUSTOM_FILTER_FUNCTION in data_filter: None
        ```
*   **Confirmation**: The `id(settings)` values were different. The `monkeypatch` in the tests was modifying an instance of `Settings` that `data_filter.py` was not using. `data_filter.py` was seeing `settings.CUSTOM_FILTER_FUNCTION` as its default value (`None`).

## Solution

The `monkeypatch.setattr` calls in `tests/test_filters.py` were changed to target the `settings` object within the namespace of the module under test (`data_filter.py`).

Instead of:
```python
# In tests/test_filters.py
from src.bsky_feed_generator.server import config
# ...
monkeypatch.setattr(config.settings, "CUSTOM_FILTER_FUNCTION", example_spongebob_filter)
```

The corrected approach patches the `settings` object as it's seen by `data_filter.py` by providing a new `Settings` instance:
```python
# In tests/test_filters.py
from src.bsky_feed_generator.server import config # Still needed for config.Settings type
# ...
monkeypatch.setattr(
    "src.bsky_feed_generator.server.data_filter.settings", # Target string for the settings object in data_filter's scope
    config.Settings(
        CUSTOM_FILTER_FUNCTION=example_spongebob_filter,
        IGNORE_ARCHIVED_POSTS=False, # Explicitly set all relevant settings for the test
        IGNORE_REPLY_POSTS=False
        # Other settings default if not specified
    )
)
```
This ensures that when `operations_callback` in `data_filter.py` accesses `settings.CUSTOM_FILTER_FUNCTION`, it sees the value set by the test.

This change was applied to all tests that modified settings relevant to `data_filter.py`.

## Outcome

After applying this correction and cleaning up diagnostic prints:
*   All 8 positive Spongebob test cases passed.
*   The `test_custom_filter_error_handling` test passed, with the correct error message being logged and captured.
*   All 28 tests in `tests/test_filters.py` passed.

## Key Takeaway

When using `pytest.monkeypatch.setattr` to modify objects or attributes from imported modules, it's crucial to target the object/attribute *where it is looked up by the code under test*, not necessarily where it's defined or imported in the test file itself. Using the string path to the object within the module under test's namespace (`"module.submodule.object_to_patch"`) is the reliable way to ensure patches are applied correctly. For complex objects like a settings instance, replacing the entire instance in the target module's namespace with a test-specific configured instance can lead to more robust and isolated tests. 