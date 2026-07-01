"""Tests for cross-sync.py"""

import datetime
import importlib.util
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

spec = importlib.util.spec_from_file_location(
    "cross_sync", "/tmp/cross-sync.py"
)
cross_sync = importlib.util.module_from_spec(spec)
sys.modules["cross_sync"] = cross_sync
spec.loader.exec_module(cross_sync)


def test_no_daily_notes(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    assert len(list(xchange.iterdir())) == 0


def test_keyword_lines(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text(
        "---\ntitle: test\n---\n"
        "fixed a bug\n"
        "deployed the app\n"
        "normal text\n"
        "---\nanother frontmatter\n---\n"
        "added feature\n"
    )

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"hermy-sync-{today.isoformat()}.md"
    assert output.exists()
    content = output.read_text("utf-8")
    assert "fixed a bug" in content
    assert "deployed the app" in content
    assert "added feature" in content
    assert "normal text" not in content
    assert "another frontmatter" not in content


def test_emoji_lines(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text("\u2705 Task completed\n\u274c Failed\nNormal line\n\U0001F680 Released\n")

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"hermy-sync-{today.isoformat()}.md"
    assert output.exists()
    content = output.read_text("utf-8")
    assert "\u2705 Task completed" in content
    assert "\u274c Failed" in content
    assert "\U0001F680 Released" in content
    assert "Normal line" not in content


def test_section_categorization(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text(
        "deployed new server\n"
        "fixed crash in auth\n"
        "switched to new dns\n"
        "planning deployed feature\n"
        "created new file\n"
    )

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"hermy-sync-{today.isoformat()}.md"
    assert output.exists()
    content = output.read_text("utf-8")

    assert "## Infrastructure Changes" in content
    assert "deployed new server" in content
    assert "created new file" in content

    assert "## Incidents & Resolutions" in content
    assert "fixed crash in auth" in content

    assert "## Decisions" in content
    assert "switched to new dns" in content

    assert "## Current Work" in content
    assert "planning deployed feature" in content


def test_old_file_cleanup(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text("fixed something\n")

    old_date = today - datetime.timedelta(days=20)
    old_file = xchange / f"hermy-sync-{old_date.isoformat()}.md"
    old_file.write_text("old content\n")

    recent_date = today - datetime.timedelta(days=5)
    recent_file = xchange / f"hermy-sync-{recent_date.isoformat()}.md"
    recent_file.write_text("recent content\n")

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"hermy-sync-{today.isoformat()}.md"
    assert output.exists()
    assert not old_file.exists()
    assert recent_file.exists()


def test_nas_missing(tmp_path):
    daily = tmp_path / "nonexistent"
    xchange = tmp_path / "xchange"
    xchange.mkdir()

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    assert len(list(xchange.iterdir())) == 0


def test_frontmatter(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text("fixed something\n")

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"hermy-sync-{today.isoformat()}.md"
    assert output.exists()
    content = output.read_text("utf-8")

    assert content.startswith("---\n")
    assert "type: reference" in content
    assert f'title: "cross-sync: hermy \u2014 {today.isoformat()}"' in content
    assert "Weekly knowledge exchange from hermy to jax" in content
    assert "tags: [cross-sync, hermy," in content
    assert "timestamp:" in content


def test_agent_jax(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text("fixed something\n")

    with patch("cross_sync.get_agent", return_value="jax"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"jax-sync-{today.isoformat()}.md"
    assert output.exists()
    content = output.read_text("utf-8")
    assert "Weekly knowledge exchange from jax to hermy" in content
    assert "tags: [cross-sync, jax," in content


def test_agent_hermy(tmp_path):
    daily = tmp_path / "daily"
    xchange = tmp_path / "xchange"
    daily.mkdir()
    xchange.mkdir()

    today = datetime.date.today()
    note = daily / f"{today.isoformat()}.md"
    note.write_text("fixed something\n")

    with patch("cross_sync.get_agent", return_value="hermy"):
        cross_sync.run(daily_dir=daily, xchange_dir=xchange)

    output = xchange / f"hermy-sync-{today.isoformat()}.md"
    assert output.exists()
    content = output.read_text("utf-8")
    assert "Weekly knowledge exchange from hermy to jax" in content
    assert "tags: [cross-sync, hermy," in content
