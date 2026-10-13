#!/usr/bin/env python3
"""Copy an existing AgentsView archive into MyType without replacing its source."""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sqlite3
import tomllib
from urllib.parse import urlparse


def encode_toml(values: dict) -> str:
    """Serialize the scalar, list and table values used in AgentsView config.

    Args:
        values: Parsed TOML configuration, including private authentication values.

    Returns:
        TOML text without printing any configuration values.
    """
    lines = []

    def table(items: dict, prefix: tuple[str, ...]) -> None:
        if prefix:
            lines.append("[" + ".".join(json.dumps(key) for key in prefix) + "]")
        for key, value in items.items():
            if not isinstance(value, dict):
                if not isinstance(value, (str, int, float, bool, list)):
                    raise ValueError("Unsupported configuration value type")
                lines.append(json.dumps(key) + " = " + json.dumps(value, ensure_ascii=False))
        lines.append("")
        for key, value in items.items():
            if isinstance(value, dict):
                table(value, (*prefix, key))

    table(values, ())
    text = "\n".join(lines)
    if tomllib.loads(text) != values:
        raise ValueError("Configuration did not round-trip")
    return text


def verify_dialogue_archive(database: Path) -> None:
    """Refuse archives with retained thinking, system prose or detailed tool payloads.

    Args:
        database: Read-only source archive. Empty accounting rows are permitted.

    Raises:
        ValueError: The archive contains broader content or has an unsupported schema.
    """
    queries = [
        "SELECT 1 FROM messages WHERE coalesce(thinking_text,'')<>'' OR "
        "((is_system<>0 OR role NOT IN ('user','assistant') OR source_subtype='tool_result') "
        "AND coalesce(content,'')<>'') LIMIT 1",
        "SELECT 1 FROM tool_calls WHERE coalesce(input_json,'')<>'' "
        "OR coalesce(result_content,'')<>'' OR coalesce(file_path,'')<>'' "
        "OR coalesce(skill_name,'')<>'' LIMIT 1",
    ]
    try:
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as connection:
            for query in queries:
                if connection.execute(query).fetchone() is not None:
                    raise ValueError("Source archive still contains non-dialogue payloads")
    except sqlite3.DatabaseError as error:
        raise ValueError("Source archive projection could not be verified") from error


def prepare(source: Path, destination: Path, home: Path, embedding_endpoint: str) -> dict:
    """Make consistent database copies and configure live, local-only ingestion.

    Args:
        source: Existing AgentsView data directory, opened read-only.
        destination: New private directory; an existing path is always refused.
        home: User home containing the original Claude and Codex logs.
        embedding_endpoint: Local Ollama OpenAI-compatible endpoint.

    Returns:
        A non-secret receipt describing copied databases and selected policy.

    Raises:
        ValueError: Configuration, source files or endpoint cannot be validated.
        FileExistsError: Destination already exists; nothing is overwritten.
    """
    endpoint = urlparse(embedding_endpoint)
    if (endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1"
            or not endpoint.port or endpoint.username or endpoint.password
            or endpoint.query or endpoint.fragment or endpoint.path != "/v1"):
        raise ValueError("Embedding endpoint must be an explicit numeric loopback /v1 URL")
    config = tomllib.loads((source / "config.toml").read_text())
    if config.get("archive_content") != "dialogue":
        raise ValueError("Source archive must already use dialogue-only storage")
    vector_path = config.get("vector", {}).get("db_path")
    if vector_path and Path(vector_path).expanduser().resolve() != (source / "vectors.db").resolve():
        raise ValueError("Source vector database must be located inside the selected data directory")
    for name in ("sessions.db", "vectors.db"):
        if not (source / name).is_file():
            raise ValueError("Both archive and vector databases are required")
    verify_dialogue_archive(source / "sessions.db")
    config["agents"]["claude"]["dirs"] = [str(home / ".claude/projects")]
    config["agents"]["codex"]["dirs"] = [
        str(home / ".codex/sessions"), str(home / ".codex/archived_sessions")]
    config["index_scope"] = {"active_days": 30, "reconcile_interval": "1h"}
    config["source_sync"] = {"reconcile_interval": "2m", "reconcile_agents": ["claude", "codex"]}
    config["vector"]["embed"].update(
        run_after_sync=True, backstop_interval="10m", max_wait="2m")
    # A copied absolute path must never direct the new daemon back into the old archive.
    config["vector"].pop("db_path", None)
    embeddings = config["vector"]["embeddings"]
    server = embeddings["servers"][embeddings["default_server"]]
    server["endpoint"] = embedding_endpoint
    config_text = encode_toml(config)
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    copied = []
    for name in ("sessions.db", "vectors.db"):
        target = destination / name
        # SQLite's backup API includes committed WAL content from a running daemon.
        with sqlite3.connect((source / name).as_uri() + "?mode=ro", uri=True) as src:
            with sqlite3.connect(target) as dst:
                src.backup(dst, pages=1024, sleep=0.01)
                if dst.execute("PRAGMA quick_check").fetchone() != ("ok",):
                    raise ValueError("Copied database failed its integrity check")
        target.chmod(0o600)
        copied.append({"name": name, "bytes": target.stat().st_size})
    verify_dialogue_archive(destination / "sessions.db")
    config_path = destination / "config.toml"
    config_path.touch(mode=0o600)
    config_path.write_text(config_text)
    receipt = {
        "prepared_at": datetime.now(timezone.utc).isoformat(),
        "source_preserved": True, "copied": copied,
        "archive_content": "dialogue", "active_days": 30,
        "source_reconciliation_seconds": 120, "after_sync_vectors": True,
        "embedding_model": embeddings["model"],
        "full_rebuild_requested": False,
    }
    (destination / "preparation-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main() -> None:
    """Prepare the explicitly selected archive using local-only default settings."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-data", type=Path, required=True)
    parser.add_argument("--destination-data", type=Path,
                        default=Path.home() / "Library/Application Support/mytype/agent-index")
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--embedding-endpoint", default="http://127.0.0.1:18741/v1")
    args = parser.parse_args()
    receipt = prepare(args.source_data.resolve(), args.destination_data.absolute(),
                      args.home.resolve(), args.embedding_endpoint)
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
