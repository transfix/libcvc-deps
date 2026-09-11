"""The non-admin web surface: sign-in, /account, and self-service tokens.

Before this, cvcpkg had no authenticated surface for anyone but an admin. The
public site had no login at all, and the OIDC callback refused every role but
``admin`` — so ``publisher`` and ``reader`` were real on the server and inert
in a browser, and the only route to a publish token was an admin minting one
by hand and couriering the secret out of band.

The security core is not the pages, it is the naming. cvcpkg keys organization
membership on a bare string (``org_members.token_name``) compared with ``==``
and no liveness check, while ``uq_tokens_active_name`` is a *partial* index and
``revoke()`` flips one boolean without touching membership rows. So a revoked
token named ``joe`` still owns every org it ever joined, and handing ``joe`` to
an SSO principal would hand over those orgs. Several tests below exist only to
hold that door shut.
"""

from __future__ import annotations

import asyncio
import base64
import json
import re

import pytest

fastapi = pytest.importorskip("fastapi", reason="server extras not installed")
aiosqlite = pytest.importorskip("aiosqlite", reason="aiosqlite required")

from fastapi.testclient import TestClient

from cvcpkg.server import oidc as oidc_mod
from cvcpkg.server import principals
from cvcpkg.server.app import create_app
from cvcpkg.server.models import TokenRole


def _form_csrf(html: str, action: str) -> str:
    """Pull the CSRF token out of one specific form."""
    m = re.search(r'<form[^>]*action="' + re.escape(action) + r'"[^>]*>(.*?)</form>', html, re.S)
    assert m, f"no form posting to {action}"
    t = re.search(r'name="_csrf" value="([0-9a-f]+)"', m.group(1))
    assert t, f"no csrf field in the {action} form"
    return t.group(1)


@pytest.fixture()
def sso_server(tmp_path, monkeypatch):
    """A DB-backed server with a stubbed identity provider."""
    db_url = f"sqlite+aiosqlite:///{tmp_path / 'acct.db'}"
    monkeypatch.setenv("CVCPKG_DATABASE_URL", db_url)
    monkeypatch.delenv("CVCPKG_MIRROR_MODE", raising=False)
    # TestClient speaks http; a Secure cookie would never come back.
    monkeypatch.setenv("CVCPKG_COOKIE_SECURE", "0")
    monkeypatch.setenv("CVCPKG_OIDC_ISSUER", "https://idp.test")
    monkeypatch.setenv("CVCPKG_OIDC_CLIENT_ID", "cid")
    monkeypatch.setenv("CVCPKG_OIDC_CLIENT_SECRET", "sec")
    monkeypatch.setenv("CVCPKG_OIDC_REDIRECT_URL", "https://x/auth/oidc/callback")
    monkeypatch.setenv("CVCPKG_OIDC_ADMIN_GROUPS", "cvcpkg-admin")
    monkeypatch.setenv("CVCPKG_OIDC_PUBLISHER_GROUPS", "cvcpkg-publisher")
    monkeypatch.setenv("CVCPKG_OIDC_DEFAULT_ROLE", "reader")

    from cvcpkg.server.db import create_tables, dispose_engine, init_db

    async def _seed():
        init_db(db_url)
        await create_tables()
        await dispose_engine()

    asyncio.run(_seed())

    state = {
        "claims": {
            "sub": "sub-1",
            "preferred_username": "pubber",
            "email": "p@x.io",
            "groups": ["cvcpkg-publisher"],
        }
    }

    async def fake_discover(cfg, **kw):
        return {
            "authorization_endpoint": "https://idp.test/auth",
            "token_endpoint": "https://idp.test/token",
            "userinfo_endpoint": "https://idp.test/userinfo",
        }

    real_build = oidc_mod.build_authorize_url

    def spy_build(endpoint, cfg, **kw):
        state["nonce"] = kw.get("nonce", "")
        return real_build(endpoint, cfg, **kw)

    async def fake_exchange(endpoint, cfg, *, code, verifier, **kw):
        body = (
            base64.urlsafe_b64encode(json.dumps({"nonce": state["nonce"]}).encode())
            .rstrip(b"=")
            .decode()
        )
        return {"access_token": "at", "id_token": f"h.{body}.s"}

    async def fake_userinfo(endpoint, access_token, **kw):
        return state["claims"]

    monkeypatch.setattr(oidc_mod, "discover", fake_discover)
    monkeypatch.setattr(oidc_mod, "build_authorize_url", spy_build)
    monkeypatch.setattr(oidc_mod, "exchange_code", fake_exchange)
    monkeypatch.setattr(oidc_mod, "fetch_userinfo", fake_userinfo)

    app = create_app(state_dir=tmp_path)
    with TestClient(app) as client:
        yield client, state, tmp_path


def _sign_in(client, next_url="/account"):
    from urllib.parse import parse_qs, urlparse

    r = client.get(f"/auth/oidc/login?next={next_url}", follow_redirects=False)
    assert r.status_code == 303, r.text
    sent = parse_qs(urlparse(r.headers["location"]).query)["state"][0]
    return client.get(f"/auth/oidc/callback?code=x&state={sent}", follow_redirects=False)


class TestSignIn:
    def test_publisher_gets_a_session_and_lands_on_account(self, sso_server):
        """The whole point: a non-admin can now sign in at all."""
        client, _, _ = sso_server
        r = _sign_in(client)
        assert r.status_code == 303, r.text
        assert r.headers["location"] == "/account"
        assert "cvcpkg_session" in r.cookies

    def test_publisher_does_not_receive_an_admin_cookie(self, sso_server):
        client, _, _ = sso_server
        r = _sign_in(client)
        assert "cvcpkg_admin_session" not in r.cookies

    def test_publisher_still_cannot_reach_the_dashboard(self, sso_server):
        """The admin gate is untouched — holding a session is not admin."""
        client, _, _ = sso_server
        _sign_in(client)
        assert "Sign in" in client.get("/admin").text

    def test_admin_gets_both_cookies(self, sso_server):
        client, state, _ = sso_server
        state["claims"] = {
            "sub": "sub-admin",
            "preferred_username": "boss",
            "groups": ["cvcpkg-admin"],
        }
        r = _sign_in(client, next_url="/admin")
        assert r.status_code == 303
        assert r.headers["location"] == "/admin"
        assert "cvcpkg_session" in r.cookies
        assert "cvcpkg_admin_session" in r.cookies

    def test_non_admin_asking_for_admin_lands_on_account_not_a_dead_end(self, sso_server):
        client, _, _ = sso_server
        r = _sign_in(client, next_url="/admin")
        assert r.headers["location"] == "/account"

    def test_unmapped_user_gets_the_default_role(self, sso_server):
        client, state, _ = sso_server
        state["claims"] = {"sub": "sub-rando", "preferred_username": "rando", "groups": []}
        assert _sign_in(client).status_code == 303
        assert ">reader<" in client.get("/account").text

    def test_anonymous_account_redirects_to_login(self, sso_server):
        client, _, _ = sso_server
        r = client.get("/account", follow_redirects=False)
        assert r.status_code == 303
        assert r.headers["location"] == "/login?next=/account"

    def test_next_is_not_an_open_redirect(self, sso_server):
        """`next` rides in the signed txn cookie and is allow-listed."""
        client, _, _ = sso_server
        r = _sign_in(client, next_url="https://evil.test/phish")
        assert r.headers["location"] in ("/account", "/admin")


class TestAccountPage:
    def test_shows_handle_role_and_how_to_be_added_to_an_org(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        assert "pubber" in page
        assert ">publisher<" in page
        assert "cvcpkg org add-member" in page

    def test_explains_where_the_role_came_from(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        assert "group membership" in client.get("/account").text

    def test_reader_is_told_how_to_get_publish_rights(self, sso_server):
        """A reader must not land on a dead end."""
        client, state, _ = sso_server
        state["claims"] = {"sub": "s-r", "preferred_username": "reader1", "groups": []}
        _sign_in(client)
        assert "cvcpkg-publisher" in client.get("/account").text

    def test_account_is_not_cached(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        assert client.get("/account").headers.get("cache-control") == "no-store"


class TestSelfServeTokens:
    def test_mint_shows_the_secret_exactly_once(self, sso_server):
        """The manual admin handoff, removed."""
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        r = client.post(
            "/account/tokens",
            data={
                "label": "laptop",
                "role": "publisher",
                "expires_in_days": "90",
                "_csrf": _form_csrf(page, "/account/tokens"),
            },
            follow_redirects=False,
        )
        assert r.status_code == 303, r.text
        after = client.get("/account").text
        assert re.search(r"cvctok_[A-Za-z0-9_\-]+", after), "secret not shown"
        assert "pubber.laptop" in after
        # Reloading must not re-show it.
        assert not re.search(r"cvctok_[A-Za-z0-9_\-]+", client.get("/account").text)

    def test_minted_token_acts_as_the_principal(self, sso_server):
        """A token row named pubber.laptop authorizes as `pubber`."""
        client, _, tmp_path = sso_server
        _sign_in(client)
        page = client.get("/account").text
        client.post(
            "/account/tokens",
            data={
                "label": "laptop",
                "role": "publisher",
                "expires_in_days": "90",
                "_csrf": _form_csrf(page, "/account/tokens"),
            },
            follow_redirects=False,
        )
        secret = re.search(r"cvctok_[A-Za-z0-9_\-]+", client.get("/account").text).group(0)
        me = client.get("/v1/whoami", headers={"Authorization": f"Bearer {secret}"})
        if me.status_code == 404:
            pytest.skip("no whoami endpoint on this build")
        assert me.json().get("name") == "pubber"

    def test_cannot_mint_above_your_own_role(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        client.post(
            "/account/tokens",
            data={
                "label": "escalate",
                "role": "admin",
                "expires_in_days": "90",
                "_csrf": _form_csrf(page, "/account/tokens"),
            },
            follow_redirects=False,
        )
        assert "cannot create" in client.get("/account").text

    def test_bad_label_is_refused(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        client.post(
            "/account/tokens",
            data={
                "label": "Not A Label",
                "role": "publisher",
                "expires_in_days": "90",
                "_csrf": _form_csrf(page, "/account/tokens"),
            },
            follow_redirects=False,
        )
        assert "Label must be" in client.get("/account").text


class TestCsrf:
    def test_mint_without_a_token_is_refused(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        r = client.post(
            "/account/tokens",
            data={"label": "x", "role": "reader", "expires_in_days": "90"},
            follow_redirects=False,
        )
        assert r.status_code == 403

    def test_a_token_from_another_form_is_refused(self, sso_server):
        """Per-form binding: a logout token cannot mint."""
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        r = client.post(
            "/account/tokens",
            data={
                "label": "x",
                "role": "reader",
                "expires_in_days": "90",
                "_csrf": _form_csrf(page, "/logout"),
            },
            follow_redirects=False,
        )
        assert r.status_code == 403

    def test_cross_origin_is_refused(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        r = client.post(
            "/account/tokens",
            data={
                "label": "x",
                "role": "reader",
                "expires_in_days": "90",
                "_csrf": _form_csrf(page, "/account/tokens"),
            },
            headers={"Origin": "https://evil.test"},
            follow_redirects=False,
        )
        assert r.status_code == 403


class TestSessionLifecycle:
    def test_logout_ends_the_session_server_side(self, sso_server):
        """A signed stateless cookie could not do this."""
        client, _, _ = sso_server
        _sign_in(client)
        page = client.get("/account").text
        r = client.post(
            "/logout", data={"_csrf": _form_csrf(page, "/logout")}, follow_redirects=False
        )
        assert r.status_code == 303
        assert client.get("/account", follow_redirects=False).status_code == 303

    def test_disabling_a_principal_ends_its_sessions_at_once(self, sso_server):
        client, _, _ = sso_server
        _sign_in(client)
        assert client.get("/account").status_code == 200

        from cvcpkg.server.identities import DbPrincipalStore

        async def disable():
            await DbPrincipalStore().set_disabled("pubber", True)

        asyncio.run(disable())
        assert client.get("/account", follow_redirects=False).status_code == 303


class TestNameAllocation:
    """The reserved-name guard — the privilege-escalation door."""

    def test_a_revoked_token_name_is_not_handed_out(self, sso_server):
        client, state, tmp_path = sso_server
        from cvcpkg.server.db_stores import DbTokenStore

        async def make_and_revoke():
            store = DbTokenStore(tmp_path)
            await store.create("pubber", TokenRole.publisher)
            await store.revoke("pubber")

        asyncio.run(make_and_revoke())
        _sign_in(client)
        page = client.get("/account").text
        # The IdP calls them "pubber"; that name is taken by a revoked token
        # which still owns any org membership it ever had.
        assert "pubber-2" in page

    def test_a_principal_name_cannot_be_claimed_by_a_new_token(self, sso_server):
        client, _, tmp_path = sso_server
        _sign_in(client)  # creates principal "pubber"

        from cvcpkg.server.db_stores import DbTokenStore

        async def claim():
            return await DbTokenStore(tmp_path).create("pubber", TokenRole.publisher)

        with pytest.raises(ValueError, match="reserved identity name"):
            asyncio.run(claim())


class TestPureNaming:
    def test_sanitize_is_total(self):
        for claims in ({}, {"sub": "x"}, {"preferred_username": "日本語", "sub": "x"}):
            name = principals.sanitize_principal_name(claims)
            assert name and principals.is_valid_name(name)

    def test_a_dot_is_never_valid_in_a_principal_name(self):
        """The dot is what separates a principal from its token labels."""
        assert not principals.is_valid_name("joe.laptop")
        assert principals.principal_of_token_name("joe.laptop") == "joe"
        assert principals.principal_of_token_name("builders") == ""

    def test_min_role_clamps(self):
        assert principals.min_role(TokenRole.admin, TokenRole.reader) == TokenRole.reader
        assert principals.min_role(TokenRole.publisher, TokenRole.admin) == TokenRole.publisher
