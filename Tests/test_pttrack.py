"""Tests for pttrack.py. Run with: python3 -m pytest"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import pttrack  # noqa: E402


@pytest.mark.parametrize("title, want", [
    ("Edit: My Song", "My Song"),
    ("Mix: My Song", "My Song"),
    ("My Song.ptx - Edit", "My Song"),
    ("Old Session.ptf", "Old Session"),
    ("", None),
])
def test_session_name(title, want):
    assert pttrack.session_name(title) == want


def test_fmt():
    assert pttrack.fmt(0) == "0h 00m"
    assert pttrack.fmt(3600 + 5 * 60) == "1h 05m"


def test_resolve_uses_linked_folder(tmp_path):
    (tmp_path / "Take 2.ptx").touch()
    links = {"Album Single": str(tmp_path)}
    assert pttrack.resolve("Take 2", links) == "Album Single"
    assert pttrack.resolve("Something Else", links) == "Something Else"


def test_log_round_trip(tmp_path, monkeypatch):
    monkeypatch.setattr(pttrack, "LOG", tmp_path / "log.json")
    assert pttrack.load() == {}
    pttrack.save({"Song": {"2026-01-01": 60}})
    assert pttrack.load() == {"Song": {"2026-01-01": 60}}
