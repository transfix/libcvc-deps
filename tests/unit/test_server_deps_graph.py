"""`/v1/deps` must include recipes that were PUSHED, not just local ones.

Regression coverage for a silent gap: the dependency graph was built only from
the server's own recipe directory, so every package published from a repo whose
recipes live elsewhere (the whole `cvc` org family — libcvc, libcvc-cuda,
cvcgl, pycvc, pycvc-gl, cvc-cli) was absent from it. Nothing errored; the
package page simply rendered no "Dependencies" and no "Used By" section, and
badged the package `community` instead of mainline.
"""

from __future__ import annotations

import asyncio
import io
import tarfile

import pytest

fastapi = pytest.importorskip("fastapi", reason="server extras not installed")
pydantic = pytest.importorskip("pydantic", reason="server extras not installed")

from fastapi.testclient import TestClient

from cvcpkg.server.app import create_app
from cvcpkg.server.models import TokenRole


def _recipe_bundle(name: str, runtime_deps: list[str]) -> bytes:
    """A minimal recipe bundle, shaped like `cvcpkg recipe push` produces."""
    body = "\n".join(
        [
            "schema_version: 1",
            "recipe:",
            f'  name: {name}',
            '  upstream_version: "1.0.0"',
            "  cvc_revision: 1",
            f'  description: "{name} test recipe"',
            "  license: MIT",
            "depends:",
            "  runtime:",
            *[f"    - name: {d}" for d in runtime_deps],
            "build:",
            "  matrix:",
            "    - platform: linux",
            "      script: build.sh",
        ]
    ).encode()

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo(f"{name}/recipe.yaml")
        info.size = len(body)
        tar.addfile(info, io.BytesIO(body))
    return buf.getvalue()


@pytest.fixture()
def server_env(tmp_path, monkeypatch):
    # Recipe distribution (and therefore the pushed half of the graph) needs a
    # DB backend; without one the upload endpoint 501s. Tokens must be seeded
    # into the DB too — the file-backed TokenStore is not consulted then.
    db_url = f"sqlite+aiosqlite:///{tmp_path / 'deps.db'}"
    monkeypatch.setenv("CVCPKG_DATABASE_URL", db_url)
    monkeypatch.delenv("CVCPKG_MIRROR_MODE", raising=False)

    from cvcpkg.server.db import create_tables, dispose_engine, init_db
    from cvcpkg.server.db_stores import DbTokenStore

    async def _seed():
        init_db(db_url)
        await create_tables()
        admin = await DbTokenStore(tmp_path).create("test-admin", TokenRole.admin)
        await dispose_engine()
        return admin

    admin_token = asyncio.run(_seed())
    app = create_app(state_dir=tmp_path)
    with TestClient(app) as client:
        yield client, admin_token


class TestDepsGraphIncludesPushedRecipes:
    def test_pushed_recipe_appears_in_graph(self, server_env):
        client, admin_token = server_env
        hdr = {"Authorization": f"Bearer {admin_token}"}

        before = client.get("/v1/deps").json()
        assert "widget" not in before.get("forward", {})

        resp = client.post(
            "/v1/recipes/widget",
            headers=hdr,
            files={"file": ("widget.tar.gz", _recipe_bundle("widget", ["zlib"]), "application/gzip")},
        )
        if resp.status_code == 501:
            pytest.skip("recipe distribution requires a DB backend")
        assert resp.status_code in (200, 201), resp.text

        after = client.get("/v1/deps").json()

        # Forward edge: the pushed recipe and its dependency.
        assert "widget" in after["forward"], "pushed recipe missing from forward graph"
        assert "zlib" in after["forward"]["widget"]

        # Reverse edge — this is what renders the "Used By" section.
        assert "widget" in after["reverse"].get("zlib", []), "reverse edge missing"

        # recipe_names drives the mainline-vs-community badge.
        assert "widget" in after["recipe_names"]

        # meta drives the description shown on the package page.
        assert after["meta"]["widget"]["description"] == "widget test recipe"

    def test_cache_invalidates_on_a_later_push(self, server_env):
        """A second push must be visible immediately, not hidden by the cache."""
        client, admin_token = server_env
        hdr = {"Authorization": f"Bearer {admin_token}"}

        first = client.post(
            "/v1/recipes/alpha",
            headers=hdr,
            files={"file": ("alpha.tar.gz", _recipe_bundle("alpha", ["zlib"]), "application/gzip")},
        )
        if first.status_code == 501:
            pytest.skip("recipe distribution requires a DB backend")

        client.get("/v1/deps")  # prime the cache

        client.post(
            "/v1/recipes/beta",
            headers=hdr,
            files={"file": ("beta.tar.gz", _recipe_bundle("beta", ["alpha"]), "application/gzip")},
        )

        after = client.get("/v1/deps").json()
        assert "beta" in after["forward"], "cache served a stale graph after a push"
        assert "beta" in after["reverse"].get("alpha", [])

    def test_malformed_bundle_does_not_blank_the_graph(self, server_env):
        """One bad bundle must not take out every other package's deps."""
        client, admin_token = server_env
        hdr = {"Authorization": f"Bearer {admin_token}"}

        good = client.post(
            "/v1/recipes/good",
            headers=hdr,
            files={"file": ("good.tar.gz", _recipe_bundle("good", ["zlib"]), "application/gzip")},
        )
        if good.status_code == 501:
            pytest.skip("recipe distribution requires a DB backend")

        client.post(
            "/v1/recipes/bad",
            headers=hdr,
            files={"file": ("bad.tar.gz", b"this is not a gzip tarball", "application/gzip")},
        )

        after = client.get("/v1/deps")
        assert after.status_code == 200
        assert "good" in after.json()["forward"], "a malformed bundle blanked the graph"
