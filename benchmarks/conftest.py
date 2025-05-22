# benchmarks/conftest.py
import json
import os
import sys

from rich.console import Console
from rich.table import Table

# This print statement helps confirm that conftest.py is being loaded by pytest.
# You might remove it once you confirm everything works.
print("benchmarks/conftest.py: Setting up logger mock for benchmark tests.")


# --- Start Logger Mocking ---
# This section MUST be active before pytest collects tests that import example_custom_filters
class MockNoOpLogger:
    def debug(self, *args, **kwargs):
        pass

    def info(self, *args, **kwargs):
        pass

    def warning(self, *args, **kwargs):
        pass

    def error(self, *args, **kwargs):
        pass

    def exception(self, *args, **kwargs):
        pass


# Create a module-like object for the logger
# This ensures that `from bsky_feed_generator.server.logger import logger` works
# and `logger` is an instance of MockNoOpLogger.
mock_logger_module = type(sys)("bsky_feed_generator.server.logger")
mock_logger_module.logger = MockNoOpLogger()

# Ensure the parent modules exist in sys.modules before placing the mock.
# This helps if tests are run from a context where these haven't been created yet
# (e.g. if pytest is run directly on the benchmarks directory without the project root in PYTHONPATH explicitly).
if "bsky_feed_generator" not in sys.modules:
    # Create a dummy bsky_feed_generator module
    sys.modules["bsky_feed_generator"] = type(sys)("bsky_feed_generator")

if "bsky_feed_generator.server" not in sys.modules:
    # Create a dummy bsky_feed_generator.server module
    sys.modules["bsky_feed_generator.server"] = type(sys)("bsky_feed_generator.server")

sys.modules["bsky_feed_generator.server.logger"] = mock_logger_module
# print("benchmarks/conftest.py: Logger mock applied to sys.modules.") # Optional: for debugging
# --- End Logger Mocking ---


def pytest_sessionfinish(session, exitstatus):
    """Hook that runs after the entire test session finishes."""
    json_output_path = "benchmark_results.json"

    # Check if the command was run with --benchmark-json (this is a bit indirect)
    # A more robust way might be to check if session.config.option.benchmark_json is set,
    # but that requires knowing the exact option name pytest-benchmark uses.
    # For now, we'll just check if the file exists, assuming if it does, it was intended for processing.
    if not os.path.exists(json_output_path):
        # print(f"\n{json_output_path} not found. Skipping custom Rich table generation.")
        return

    console = Console()
    console.print("\n[bold cyan]Benchmark Summary (Mean Times):[/bold cyan]")

    table = Table(show_header=True, header_style="bold magenta")
    table.add_column("Test Case Name", style="dim", width=60)
    table.add_column("Mean Time (ns)", justify="right", width=20)

    benchmark_data = []
    grand_total_time_seconds = 0.0  # Initialize grand total time
    try:
        with open(json_output_path) as f:
            data = json.load(f)

        for benchmark_run in data.get("benchmarks", []):
            full_name = benchmark_run.get("name", "Unknown Test")
            name_parts = full_name.split("[")
            display_name = (
                name_parts[-1][:-1]
                if len(name_parts) > 1 and name_parts[-1].endswith("]")
                else full_name
            )

            stats = benchmark_run.get("stats", {})
            mean_time_seconds = stats.get("mean", 0)
            mean_time_ns = mean_time_seconds * 1e9  # Convert to nanoseconds
            benchmark_data.append((display_name, mean_time_ns))

            # Add to grand total
            grand_total_time_seconds += stats.get("total", 0)

            table.add_row(
                display_name,
                f"{mean_time_ns:,.2f}",  # Format with commas and 2 decimal places
            )

        # Print Grand Total Time first
        grand_total_time_ms = grand_total_time_seconds * 1000
        console.print(
            f"[bold green]Total Combined Benchmark Execution Time: {grand_total_time_ms:,.2f} ms ({grand_total_time_seconds:,.3f} s)[/bold green]\\n"
        )

        console.print(table)

        # Highlight Top N slowest tests
        if benchmark_data:
            benchmark_data.sort(
                key=lambda x: x[1], reverse=True
            )  # Sort by mean_time_ns descending
            top_n = 5
            console.print(
                f"\n[bold yellow]Top {top_n} Slowest Test Cases (Mean Time):[/bold yellow]"
            )
            slow_table = Table(show_header=True, header_style="bold red")
            slow_table.add_column("Test Case Name", style="dim", width=60)
            slow_table.add_column("Mean Time (ns)", justify="right", width=20)
            for i in range(min(top_n, len(benchmark_data))):
                name, time_ns = benchmark_data[i]
                slow_table.add_row(name, f"{time_ns:,.2f}")
            console.print(slow_table)

    except Exception as e:
        console.print(f"[bold red]Error processing {json_output_path}:[/bold red] {e}")
    finally:
        # Clean up the JSON file
        if os.path.exists(json_output_path):
            try:
                os.remove(json_output_path)
                # console.print(f"Successfully removed {json_output_path}.") # Optional debug message
            except Exception as e:
                console.print(
                    f"[bold red]Error removing {json_output_path}:[/bold red] {e}"
                )
