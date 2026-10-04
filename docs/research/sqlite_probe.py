#!/usr/bin/env python3
"""Reproduce Mosaic's change-token experiment using only disposable synthetic data.

Run: python3 docs/research/sqlite_probe.py
This never opens ~/Library/Messages/chat.db or any other existing database.
The schema deliberately has no explicit indexes; timings are not app benchmarks.
"""

import argparse
import json
import platform
import sqlite3
import statistics
import tempfile
import time
from pathlib import Path


def run(message_count: int, attachment_count: int, rounds: int) -> dict:
    with tempfile.TemporaryDirectory(prefix="mosaic-research-") as folder:
        path = Path(folder) / "synthetic.db"
        writer = sqlite3.connect(path)
        reader = None
        try:
            writer.executescript(
                """
                PRAGMA journal_mode=WAL;
                CREATE TABLE message (
                    text TEXT, date INTEGER, date_delivered INTEGER,
                    date_read INTEGER, date_edited INTEGER,
                    date_retracted INTEGER, is_read INTEGER, error INTEGER
                );
                CREATE TABLE chat (display_name TEXT);
                CREATE TABLE chat_message_join (
                    chat_id INTEGER, message_id INTEGER
                );
                CREATE TABLE attachment (transfer_state INTEGER);
                INSERT INTO chat VALUES ('Synthetic');
                """
            )
            writer.executemany(
                "INSERT INTO message VALUES (?,?,?,?,?,?,?,?)",
                ((f"message-{i}", i, i, i, 0, 0, 0, 0)
                 for i in range(1, message_count + 1)),
            )
            writer.executemany(
                "INSERT INTO chat_message_join VALUES (1,?)",
                ((i,) for i in range(1, message_count + 1)),
            )
            writer.executemany(
                "INSERT INTO attachment VALUES (?)",
                ((1,) for _ in range(attachment_count)),
            )
            writer.commit()
            reader = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
            parts = [
                "(SELECT COUNT(*) FROM message)",
                "(SELECT MAX(ROWID) FROM message)",
                *[f"(SELECT MAX({column}) FROM message)" for column in (
                    "date", "date_delivered", "date_read", "date_edited",
                    "date_retracted",
                )],
                "(SELECT COUNT(*) FROM chat)",
                "(SELECT MAX(ROWID) FROM chat_message_join)",
                "(SELECT COUNT(*) FROM attachment)",
                "(SELECT SUM(transfer_state) FROM attachment)",
            ]
            query = "SELECT " + ", ".join(parts)
            before = reader.execute(query).fetchone()
            initial_version = reader.execute("PRAGMA data_version").fetchone()[0]
            writer.execute(
                "UPDATE message SET text=?, is_read=1, error=42 WHERE rowid=1",
                ("edited older message",),
            )
            writer.execute("UPDATE chat SET display_name=?", ("Renamed chat",))
            writer.commit()
            after = reader.execute(query).fetchone()
            final_version = reader.execute("PRAGMA data_version").fetchone()[0]
            result = {
                "environment": {
                    "platform": platform.platform(),
                    "python": platform.python_version(),
                    "sqlite": sqlite3.sqlite_version,
                },
                "fixture": {
                    "messages": message_count,
                    "attachments": attachment_count,
                    "indexes": "none except implicit ROWID",
                    "rounds": rounds,
                },
                "aggregate_missed_content_status_chatname_changes": before == after,
                "persistent_reader_data_version_detected_changes": (
                    initial_version != final_version
                ),
            }
            for label, sql in (
                ("fingerprint", query), ("data_version", "PRAGMA data_version")
            ):
                reader.execute(sql).fetchone()  # Warm the query.
                samples = []
                for _ in range(rounds):
                    start = time.perf_counter()
                    reader.execute(sql).fetchone()
                    samples.append((time.perf_counter() - start) * 1000)
                result[label + "_milliseconds"] = {
                    "median": round(statistics.median(samples), 3),
                    "min": round(min(samples), 3),
                    "max": round(max(samples), 3),
                }
            return result
        finally:
            if reader is not None:
                reader.close()
            writer.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--messages", type=int, default=250_000)
    parser.add_argument("--attachments", type=int, default=50_000)
    parser.add_argument("--rounds", type=int, default=20)
    args = parser.parse_args()
    if args.messages < 1 or args.attachments < 0 or args.rounds < 1:
        parser.error("messages and rounds must be positive; attachments must be nonnegative")
    print(json.dumps(run(args.messages, args.attachments, args.rounds), indent=2))
