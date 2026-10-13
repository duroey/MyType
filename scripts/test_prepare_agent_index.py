"""Behavioral checks for the non-destructive AgentsView migration."""

import importlib.util
from pathlib import Path
import sqlite3
import tempfile
import tomllib
import unittest

spec = importlib.util.spec_from_file_location(
    "prepare_agent_index", Path(__file__).with_name("prepare-agent-index.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PreparationTests(unittest.TestCase):
    """Exercise preserved data and rejected migrations using isolated archives."""

    def setUp(self):
        """Create small source archives that include uncheckpointed WAL records."""
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.config = {
            "archive_content": "dialogue", "auth_token": "fixture-only",
            "agents": {"claude": {"dirs": ["snapshot"]}, "codex": {"dirs": ["snapshot"]}},
            "vector": {"embed": {}, "embeddings": {
                "model": "fixture", "default_server": "local",
                "servers": {"local": {"endpoint": "http://127.0.0.1:1/v1"}}}},
        }
        (self.source / "config.toml").write_text(module.encode_toml(self.config))
        for name in ("sessions.db", "vectors.db"):
            db = sqlite3.connect(self.source / name)
            self.addCleanup(db.close)
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE retained(value INTEGER)")
            db.execute("INSERT INTO retained VALUES (42)")
            if name == "sessions.db":
                db.execute("CREATE TABLE messages(thinking_text TEXT, is_system INTEGER, role TEXT, source_subtype TEXT, content TEXT)")
                db.execute("CREATE TABLE tool_calls(input_json TEXT, result_content TEXT, file_path TEXT, skill_name TEXT)")
                db.execute("INSERT INTO messages VALUES ('',0,'user',NULL,'visible fixture')")
                db.execute("INSERT INTO tool_calls VALUES ('','','','')")
            db.commit()

    def test_preserves_archive_vectors_and_source(self):
        """Copy committed WAL content and update only the new runtime policy."""
        destination = self.root / "destination"
        module.prepare(self.source, destination, self.root / "home", "http://127.0.0.1:18741/v1")
        for name in ("sessions.db", "vectors.db"):
            with sqlite3.connect(destination / name) as db:
                self.assertEqual(db.execute("SELECT value FROM retained").fetchone(), (42,))
        configured = tomllib.loads((destination / "config.toml").read_text())
        self.assertEqual(configured["index_scope"]["active_days"], 30)
        self.assertTrue(configured["vector"]["embed"]["run_after_sync"])
        self.assertEqual(configured["auth_token"], "fixture-only")
        self.assertEqual(configured["agents"]["claude"]["dirs"], [str(self.root / "home/.claude/projects")])
        self.assertEqual(tomllib.loads((self.source / "config.toml").read_text()), self.config)
        self.assertEqual((destination / "config.toml").stat().st_mode & 0o777, 0o600)

    def test_never_overwrites_existing_destination(self):
        """Refuse an existing archive before modifying any of its files."""
        destination = self.root / "existing"
        destination.mkdir()
        marker = destination / "sessions.db"
        marker.write_text("keep")
        with self.assertRaises(FileExistsError):
            module.prepare(self.source, destination, self.root, "http://127.0.0.1:18741/v1")
        self.assertEqual(marker.read_text(), "keep")

    def test_rejects_external_embedding_destination(self):
        """Refuse external hosts without creating a runtime directory."""
        destination = self.root / "external"
        with self.assertRaises(ValueError):
            module.prepare(self.source, destination, self.root, "https://example.com/v1")
        self.assertFalse(destination.exists())

    def test_rejects_full_content_archive(self):
        """Do not silently import tools or thinking from a broader archive."""
        self.config["archive_content"] = "full"
        (self.source / "config.toml").write_text(module.encode_toml(self.config))
        with self.assertRaises(ValueError):
            module.prepare(self.source, self.root / "full", self.root, "http://127.0.0.1:18741/v1")

    def test_relocates_explicit_vector_path(self):
        """Keep new vector writes confined to the copied runtime directory."""
        self.config["vector"]["db_path"] = str(self.source / "vectors.db")
        (self.source / "config.toml").write_text(module.encode_toml(self.config))
        destination = self.root / "relocated"
        module.prepare(self.source, destination, self.root, "http://127.0.0.1:18741/v1")
        configured = tomllib.loads((destination / "config.toml").read_text())
        self.assertNotIn("db_path", configured["vector"])

    def test_rejects_external_vector_path(self):
        """Require an explicit export when the source archive uses an external vector database."""
        self.config["vector"]["db_path"] = str(self.root / "elsewhere/vectors.db")
        (self.source / "config.toml").write_text(module.encode_toml(self.config))
        with self.assertRaises(ValueError):
            module.prepare(self.source, self.root / "external-vector", self.root, "http://127.0.0.1:18741/v1")

    def test_rejects_payloads_even_when_config_says_dialogue(self):
        """Check actual archive contents rather than trusting a configuration label."""
        with sqlite3.connect(self.source / "sessions.db") as database:
            database.execute("UPDATE tool_calls SET result_content='hidden tool payload'")
        destination = self.root / "hidden"
        with self.assertRaises(ValueError):
            module.prepare(self.source, destination, self.root, "http://127.0.0.1:18741/v1")
        self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
