#!/usr/bin/env python3
"""Reconcile catalog DB rows whose sha256/size disagree with the on-disk archive.

Background: a race in POST /v1/upload/{id}/complete (fixed alongside this
script) could clobber an existing archive on disk when a second publisher
completed a chunked upload for an already-published NVR. The rename over the
destination file succeeded, but the follow-up ``add_package`` insert failed on
the unique index, leaving DB.sha256/size out of sync with the file that
downloaders actually receive.

This tool re-hashes every archive under ``$CVCPKG_STATE_DIR/archives`` and,
for each row whose (sha256, size_bytes) disagrees with the file on disk,
updates the DB row to match reality. It also records an audit-log entry per
fix.

Two modes:

  --dry-run   (default) Print the drift set only.
  --apply     Perform UPDATEs and audit records.

The script only ever *shrinks* drift — it never deletes archives or DB rows.

Usage from inside the running backend container::

    docker exec -it cvcpkg-prod-backend \\
        python -m cvcpkg.scripts.reconcile_archive_drift
    docker exec -it cvcpkg-prod-backend \\
        python -m cvcpkg.scripts.reconcile_archive_drift --apply
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import select, update

from cvcpkg.server.db import PackageRow, dispose_engine, get_session, init_db
from cvcpkg.server.db_stores import DbAuditLog
from cvcpkg.server.models import AuditAction


CHUNK = 4 * 1024 * 1024


def _sha256_and_size(path: Path) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as f:
        for buf in iter(lambda: f.read(CHUNK), b""):
            h.update(buf)
            size += len(buf)
    return h.hexdigest(), size


@dataclass
class Drift:
    row_id: int
    name: str
    version: str
    platform: str
    arch: str
    build_type: str
    link: str
    archive_url: str
    db_sha: str
    db_size: int
    disk_sha: str
    disk_size: int
    archive_path: Path


async def _collect_drift(archives_dir: Path, verbose: bool) -> list[Drift]:
    drift: list[Drift] = []
    async with get_session() as session:
        result = await session.execute(select(PackageRow))
        rows = result.scalars().all()

    for row in rows:
        filename = row.archive_url.rsplit("/", 1)[-1]
        path = archives_dir / filename
        if not path.exists():
            if verbose:
                print(
                    f"MISSING|{row.name}|{row.version}|{row.platform}|{row.arch}"
                    f"|{row.build_type}|{row.link}|{filename}",
                    flush=True,
                )
            continue
        disk_sha, disk_size = _sha256_and_size(path)
        if disk_sha == row.sha256 and disk_size == row.size_bytes:
            continue
        drift.append(
            Drift(
                row_id=row.id,
                name=row.name,
                version=row.version,
                platform=row.platform,
                arch=row.arch,
                build_type=row.build_type,
                link=row.link,
                archive_url=row.archive_url,
                db_sha=row.sha256,
                db_size=row.size_bytes,
                disk_sha=disk_sha,
                disk_size=disk_size,
                archive_path=path,
            )
        )
    return drift


def _print_report(drift: list[Drift]) -> None:
    if not drift:
        print("no drift detected", flush=True)
        return
    print(
        "id|name|version|platform|arch|build_type|link"
        "|db_sha256|db_size|disk_sha256|disk_size",
        flush=True,
    )
    for d in drift:
        print(
            f"{d.row_id}|{d.name}|{d.version}|{d.platform}|{d.arch}|{d.build_type}"
            f"|{d.link}|{d.db_sha}|{d.db_size}|{d.disk_sha}|{d.disk_size}",
            flush=True,
        )
    print(f"total drift rows: {len(drift)}", flush=True)


async def _apply(drift: list[Drift], actor: str) -> None:
    async with get_session() as session:
        for d in drift:
            await session.execute(
                update(PackageRow)
                .where(PackageRow.id == d.row_id)
                .values(sha256=d.disk_sha, size_bytes=d.disk_size)
            )
        await session.commit()

    audit = DbAuditLog()
    for d in drift:
        # No dedicated action for reconciliation; catalog_rebuild is the
        # closest existing entry and reads sensibly in the audit trail.
        await audit.record(
            action=AuditAction.catalog_rebuild,
            actor=actor,
            target=f"{d.name}=={d.version}",
            detail=(
                f"reconcile_archive_drift platform={d.platform} arch={d.arch} "
                f"build_type={d.build_type} link={d.link} "
                f"old_sha={d.db_sha} old_size={d.db_size} "
                f"new_sha={d.disk_sha} new_size={d.disk_size}"
            ),
        )


async def _main_async(args: argparse.Namespace) -> int:
    db_url = os.environ.get("CVCPKG_DATABASE_URL")
    if not db_url:
        print("CVCPKG_DATABASE_URL must be set", file=sys.stderr)
        return 2
    state_dir = Path(os.environ.get("CVCPKG_STATE_DIR", "/app/data"))
    archives_dir = state_dir / "archives"
    if not archives_dir.is_dir():
        print(f"archives dir does not exist: {archives_dir}", file=sys.stderr)
        return 2

    init_db(db_url)
    try:
        drift = await _collect_drift(archives_dir, verbose=args.verbose)
        _print_report(drift)
        if not drift:
            return 0
        if args.apply:
            await _apply(drift, actor=args.actor)
            print(f"applied {len(drift)} DB reconciliations", flush=True)
        else:
            print("dry-run: no changes made. rerun with --apply to fix.", flush=True)
        return 0
    finally:
        await dispose_engine()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--apply",
        action="store_true",
        help="Perform UPDATEs. Without this, script only prints drift set.",
    )
    p.add_argument(
        "--actor",
        default="reconcile-script",
        help="Actor name recorded in the audit log for each update.",
    )
    p.add_argument(
        "--verbose",
        action="store_true",
        help="Also report DB rows whose archive file is missing on disk.",
    )
    args = p.parse_args()
    return asyncio.run(_main_async(args))


if __name__ == "__main__":
    raise SystemExit(main())
