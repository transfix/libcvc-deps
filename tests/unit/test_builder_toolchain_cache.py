"""Cross-toolchain cache readiness — the shared-cache race between jobs.

Builders run several cross-compilation jobs concurrently against ONE toolchain
cache.  The cache used to be considered usable when its directory merely
existed and was non-empty, which is true the instant the first job writes its
download into that directory.  A second job then symlinked a half-unpacked
toolchain into its build prefix; for emsdk that surfaces as

    Error: unable to determine 'emsdk' directory. Perhaps you are using a shell…

because emsdk_env.sh checks for emsdk.py, which had not been extracted yet.
Every wasm job on the builder failed that way.
"""

from __future__ import annotations

from pathlib import Path

from cvcpkg.cli._builder import (
    _TC_CACHE_MARKER,
    _symlink_merge_into,
    _toolchain_cache_ready,
)


def test_missing_cache_is_not_ready(tmp_path: Path) -> None:
    assert not _toolchain_cache_ready(tmp_path / "emsdk-5.0.7+cvc.1")


def test_partially_extracted_cache_is_not_ready(tmp_path: Path) -> None:
    """The race state: non-empty, but mid-extraction and missing emsdk.py."""
    cache = tmp_path / "emsdk-5.0.7+cvc.1"
    cache.mkdir()
    # What a concurrent job has produced so far: its download, plus whatever
    # the archive has unpacked at this instant.
    (cache / "_toolchain_emsdk.tar.gz").write_bytes(b"\x1f\x8b partial")
    (cache / "emsdk_env.sh").write_text("#!/bin/sh\n")
    assert any(cache.iterdir())  # the old readiness test would have said yes
    assert not _toolchain_cache_ready(cache)


def test_completed_cache_is_ready(tmp_path: Path) -> None:
    cache = tmp_path / "emsdk-5.0.7+cvc.1"
    cache.mkdir()
    (cache / "emsdk.py").write_text("# emsdk\n")
    (cache / _TC_CACHE_MARKER).write_text("emsdk 5.0.7+cvc.1\n")
    assert _toolchain_cache_ready(cache)


def test_symlink_merge_publishes_top_level_files(tmp_path: Path) -> None:
    """emsdk_env.sh resolves its directory and requires emsdk.py beside it.

    Top-level FILES must reach the build prefix, not just directories --
    a prefix with emsdk_env.sh but no emsdk.py is exactly the broken state.
    """
    cache = tmp_path / "cache"
    (cache / "upstream" / "emscripten").mkdir(parents=True)
    (cache / "emsdk.py").write_text("# emsdk\n")
    (cache / "emsdk_env.sh").write_text("#!/bin/sh\n")
    (cache / "upstream" / "emscripten" / "emcc").write_text("#!/bin/sh\n")

    prefix = tmp_path / "prefix"
    (prefix / "bin").mkdir(parents=True)  # a dependency already installed here
    (prefix / "bin" / "cmake").write_text("#!/bin/sh\n")

    _symlink_merge_into(cache, prefix)

    assert (prefix / "emsdk.py").is_file()
    assert (prefix / "emsdk_env.sh").is_file()
    assert (prefix / "upstream" / "emscripten" / "emcc").is_file()
    # The dependency's own tree survives the merge.
    assert (prefix / "bin" / "cmake").is_file()
