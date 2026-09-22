#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# glucose-fetch - collect CGM readings and print one normalized JSON payload.
#
# Sources:
#   librelinkup  Abbott LibreLinkUp ("瞬感通") cloud, read-only follower API
#   nightscout   Any Nightscout instance (self-hosted, or fed by
#                nightscout-librelink-up)
#   mock         Synthetic data, for developing the widget without an account
#
# Stdlib only, no pip installs. The shell runs this on a timer and parses
# stdout; diagnostics go to stderr so stdout always stays valid JSON.
#
# The payload contract (see README.md): everything is normalized to mg/dL and
# UTC epoch seconds, because the display unit and the time window are the
# widget's business, not the fetcher's.

import argparse
import base64
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

DEFAULT_CONFIG = "~/.config/omarchy/glucose/config.json"
DEFAULT_CACHE = "~/.local/state/glucose/last.json"

# LibreLinkUp requires a client identity; the server rejects unknown products.
LLU_PRODUCT = "llu.ios"
LLU_VERSION = "4.17.0"
LLU_UA = "Mozilla/5.0"

# Region code -> API host. CN and RU are separate domains entirely, matching
# what the official apps use; everything else is api-<region>.libreview.io.
REGION_HOSTS = {
    "ae": "api-ae.libreview.io",
    "ap": "api-ap.libreview.io",
    "au": "api-au.libreview.io",
    "ca": "api-ca.libreview.io",
    "de": "api-de.libreview.io",
    "eu": "api-eu.libreview.io",
    "eu2": "api-eu2.libreview.io",
    "fr": "api-fr.libreview.io",
    "jp": "api-jp.libreview.io",
    "la": "api-la.libreview.io",
    "us": "api-us.libreview.io",
    "ru": "api.libreview.ru",
    "cn": "api-cn.myfreestyle.cn",
}
# Probe order when the region is not configured. CN first: a CN account will
# never resolve through the global endpoint, and a wrong-region login costs
# one cheap 911 response.
REGION_PROBE_ORDER = ["cn", "eu", "eu2", "us", "de", "fr", "ap", "au", "ca", "jp", "la", "ae", "ru"]

MGDL_PER_MMOL = 18.0182

# LibreLinkUp trend arrows; 1..5 is the frozen set the API emits.
TREND_GLYPHS = {0: "?", 1: "\u2193", 2: "\u2198", 3: "\u2192", 4: "\u2197", 5: "\u2191"}


def log(message):
    sys.stderr.write("glucose-fetch: %s\n" % message)
    sys.stderr.flush()


def debug(enabled, message):
    if enabled:
        log(message)


# --------------------------------------------------------------------------
# config
# --------------------------------------------------------------------------

def expand(path):
    return os.path.expanduser(path)


def load_config(path, required=True):
    path = expand(path)
    if not os.path.exists(path):
        if required:
            raise ConfigError(
                "config not found: %s (copy config.example.json from the plugin "
                "directory and fill it in)" % path
            )
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    try:
        return json.loads(text)
    except ValueError as exc:
        raise ConfigError("config is not valid JSON (%s): %s" % (path, exc))


class ConfigError(Exception):
    pass


class FetchError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------

def http_json(url, method="GET", headers=None, body=None, timeout=15, attempts=2):
    """Return (status_code, parsed_json_or_None, raw_text).

    Transport failures are retried once: the widget polls on a timer, and a
    single dropped packet while the laptop wakes should not surface as an
    error banner. HTTP error statuses are never retried here — the API reports
    semantic failures in the body and the caller decides what they mean.
    """
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")

    last_error = None
    for attempt in range(max(1, attempts)):
        request = urllib.request.Request(url, data=data, method=method)
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read().decode("utf-8", "replace")
                return response.status, safe_json(raw), raw
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            # The API reports semantic failures as JSON bodies with HTTP errors,
            # so hand the body back rather than raising on every non-200.
            if exc.code in (429, 500, 502, 503, 504) and attempt + 1 < attempts:
                last_error = exc
                time.sleep(2 * (attempt + 1))
                continue
            return exc.code, safe_json(raw), raw
        except (urllib.error.URLError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            last_error = FetchError("network", "cannot reach %s: %s" % (url, reason))
            if attempt + 1 < attempts:
                time.sleep(2 * (attempt + 1))
                continue
            raise last_error
    raise last_error or FetchError("network", "cannot reach %s" % url)


def safe_json(raw):
    try:
        return json.loads(raw)
    except ValueError:
        return None


# --------------------------------------------------------------------------
# LibreLinkUp
# --------------------------------------------------------------------------

def llu_host(region):
    region = (region or "").lower()
    if region in REGION_HOSTS:
        return "https://" + REGION_HOSTS[region]
    if region:
        return "https://api-%s.libreview.io" % region
    return "https://api.libreview.io"


def jwt_claims(token):
    """Read the (unverified) payload of an auth ticket.

    Nothing here is trusted for authorization — the server already decided that
    — but `role` and `region` turn a bare "no connections" into an actionable
    message, and they save a support round trip.
    """
    try:
        payload = str(token).split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
    except Exception:  # noqa: BLE001 - diagnostics must never break the fetch
        return {}


def llu_login_headers():
    return {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": LLU_UA,
        "product": LLU_PRODUCT,
        "version": LLU_VERSION,
    }


def llu_auth_headers(token, account_id):
    headers = llu_login_headers()
    headers["Authorization"] = "Bearer %s" % token
    headers["Account-Id"] = account_id
    return headers


def llu_attempt_login(email, password, region, verbose):
    url = "%s/llu/auth/login" % llu_host(region)
    debug(verbose, "login -> %s" % url)
    _, payload, raw = http_json(url, "POST", llu_login_headers(), {"email": email, "password": password})
    if payload is None:
        raise FetchError("protocol", "login returned non-JSON: %s" % raw[:200])

    status = payload.get("status")
    data = payload.get("data") if isinstance(payload.get("data"), dict) else {}

    if status == 0 and data.get("redirect") and data.get("region"):
        return {"redirect": data["region"]}
    if status == 0:
        ticket = data.get("authTicket") or {}
        user = data.get("user") or {}
        token = ticket.get("token")
        user_id = user.get("id")
        if not token or not user_id:
            raise FetchError("protocol", "login succeeded but no token/user id in response")
        return {
            "token": token,
            "expires": ticket.get("expires") or 0,
            "userId": user_id,
            # The follower API authenticates the second factor as a hash of the
            # account id, not the raw id.
            "accountId": hashlib.sha256(str(user_id).lower().encode("utf-8")).hexdigest(),
            "region": region or "",
            "claims": jwt_claims(token),
        }
    if status == 911:
        raise FetchError("region", "account is not on region %s" % (region or "global"))
    if status == 4:
        raise FetchError(
            "terms",
            "Abbott requires accepting new Terms of Use: open the official "
            "Libre app (瞬感宝) or LibreLinkUp (瞬感通) once to accept, then retry",
        )
    if status == 2:
        detail = ""
        error = payload.get("error")
        if isinstance(error, dict):
            detail = str(error.get("message") or "")
        raise FetchError(
            "auth",
            "LibreLinkUp rejected the credentials (%s). LibreLinkUp logs in with a "
            "full email address, not a username, and that account must be "
            "registered in LibreLinkUp (\u77ac\u611f\u901a) and already be following "
            "your sensor. The Libre app (\u77ac\u611f\u5b9d) password is usually the same."
            % (detail or "incorrect username/password"),
        )

    message = payload.get("message") or payload.get("error") or ""
    raise FetchError("protocol", "login failed (status %s) %s" % (status, message))


def llu_login(email, password, region, verbose):
    """Log in, discovering the region when it is unknown."""
    if region:
        result = llu_attempt_login(email, password, region, verbose)
        if "redirect" in result:
            return llu_attempt_login(email, password, result["redirect"], verbose), result["redirect"]
        return result, region

    # No configured region: the global endpoint answers with the account's
    # region, and a 911 there tells us to probe.
    try:
        result = llu_attempt_login(email, password, "", verbose)
        if "redirect" in result:
            target = result["redirect"]
            return llu_attempt_login(email, password, target, verbose), target
        return result, ""
    except FetchError as exc:
        if exc.code not in ("region", "protocol"):
            raise

    last_error = None
    for candidate in REGION_PROBE_ORDER:
        try:
            result = llu_attempt_login(email, password, candidate, verbose)
            if "redirect" in result:
                return llu_attempt_login(email, password, result["redirect"], verbose), result["redirect"]
            return result, candidate
        except FetchError as exc:
            if exc.code in ("auth", "terms"):
                raise
            last_error = exc
    raise last_error or FetchError("region", "could not determine the account region")


def parse_llu_timestamp(text, assume_utc):
    """Parse LibreLinkUp's `M/D/YYYY h:mm:ss AM` stamps.

    `FactoryTimestamp` is UTC by definition; `Timestamp` is the patient's
    local wall clock, which is why the UTC field is preferred whenever the
    API provides it.
    """
    if not text:
        return None
    for fmt in ("%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %H:%M:%S"):
        try:
            parsed = datetime.strptime(text.strip(), fmt)
        except ValueError:
            continue
        if assume_utc:
            return int(parsed.replace(tzinfo=timezone.utc).timestamp())
        # Local wall clock: let the OS resolve the offset.
        return int(parsed.astimezone().timestamp())
    return None


def measurement_epoch(entry):
    utc = parse_llu_timestamp(entry.get("FactoryTimestamp"), True)
    if utc is not None:
        return utc
    return parse_llu_timestamp(entry.get("Timestamp"), False)


def measurement_value(entry, uom):
    """Normalize a measurement to mg/dL."""
    mgdl = entry.get("ValueInMgPerDl")
    if isinstance(mgdl, (int, float)) and mgdl > 0:
        return float(mgdl)
    value = entry.get("Value")
    if isinstance(value, (int, float)) and value > 0:
        return float(value) if uom != 2 else float(value) * MGDL_PER_MMOL
    return None


def target_to_mgdl(value, uom):
    if not isinstance(value, (int, float)):
        return None
    return float(value) if uom != 2 else float(value) * MGDL_PER_MMOL


def llu_session(section, verbose):
    """Log in (or reuse a live cached ticket) and return (session, host)."""
    email = (section.get("email") or "").strip()
    password = section.get("password") or ""
    if not email or not password:
        raise ConfigError("librelinkup.email / librelinkup.password are not set")

    # Reuse a cached token when it still has life left: the API rate-limits
    # logins, and the widget polls every minute.
    token_cache_path = expand(section.get("tokenCache") or "~/.local/state/glucose/token.json")
    guard_path = expand(section.get("guardCache") or "~/.local/state/glucose/login-guard.json")
    session = None
    cached = load_json_file(token_cache_path)
    if cached and cached.get("token") and cached.get("accountId"):
        if float(cached.get("expires") or 0) > time.time() + 300:
            session = cached
            debug(verbose, "reusing cached LibreLinkUp token (region %s)" % cached.get("region"))

    if session is None:
        state = login_guard_check(guard_path)
        try:
            session, region = llu_login(email, password, (section.get("region") or "").strip().lower(), verbose)
        except FetchError as exc:
            # Wrong credentials would otherwise be retried on every poll, which
            # is how you get an account locked out. Back off after a few tries.
            if exc.code == "auth":
                login_guard_fail(guard_path, state)
            raise
        login_guard_clear(guard_path)
        session["region"] = region
        session.setdefault("email", email)
        write_json_file(token_cache_path, session)
        debug(verbose, "logged in, region=%s" % (region or "auto"))

    host = llu_host(session.get("region") or section.get("region"))
    return session, host


def llu_connections(session, host):
    """Return the raw /llu/connections list for a logged-in session."""
    status, payload, raw = http_json(
        "%s/llu/connections" % host, "GET", llu_auth_headers(session["token"], session["accountId"])
    )
    if payload is None or payload.get("status") != 0:
        token_cache_path = expand("~/.local/state/glucose/token.json")
        if os.path.exists(token_cache_path):
            try:
                os.remove(token_cache_path)
            except OSError:
                pass
        code = "auth" if (payload or {}).get("status") == 401 or status == 401 else "protocol"
        raise FetchError(code, "connections request failed (http %s)" % status)
    return payload.get("data") or []


def fetch_librelinkup(section, hours, verbose):
    session, host = llu_session(section, verbose)
    connections = llu_connections(session, host)
    if not isinstance(connections, list) or not connections:
        # Derive on demand: a session restored from the token cache predates any
        # `claims` key, and re-logging in just to read the role would burn a
        # login against the rate limiter.
        claims = session.get("claims") or jwt_claims(session.get("token"))
        role = str(claims.get("role") or "")
        region = str(session.get("region") or claims.get("region") or "?").upper()
        if role == "patient":
            # The classic trap: the 瞬感宝 login is also a valid LibreLinkUp
            # login, but as the patient it follows nobody, so every data call
            # comes back empty until a follower link exists.
            raise FetchError(
                "no-share",
                "logged in fine, but this is the patient account itself "
                "(role=patient, region %s), which follows nobody — so there is no "
                "sensor to read. Create a follower link first: in the Libre app "
                "(瞬感宝) open 共享/数据共享 and invite an email, then log in to "
                "LibreLinkUp (瞬感通) with that email and accept the invitation. "
                "Inviting this very same address works too, as long as it is accepted."
                % region,
            )
        raise FetchError(
            "no-share",
            "this LibreLinkUp account is following nobody (role=%s). In the Libre app "
            "(瞬感宝) invite the LibreLinkUp email, then accept it in 瞬感通."
            % (role or "unknown"),
        )

    wanted = (section.get("patientId") or "").strip().lower()
    connection = None
    for candidate in connections:
        if wanted and str(candidate.get("patientId") or "").lower() == wanted:
            connection = candidate
            break
    if connection is None:
        connection = connections[0]

    patient_id = connection.get("patientId")
    uom = connection.get("uom")
    target_low = target_to_mgdl(connection.get("targetLow"), uom)
    target_high = target_to_mgdl(connection.get("targetHigh"), uom)

    token = session["token"]
    account_id = session["accountId"]

    graph = None
    status, graph_payload, raw = http_json(
        "%s/llu/connections/%s/graph" % (host, urllib.parse.quote(str(patient_id))),
        "GET",
        llu_auth_headers(token, account_id),
    )
    if graph_payload and graph_payload.get("status") == 0:
        graph = graph_payload.get("data") or {}

    series = []
    current = None

    if isinstance(graph, dict):
        conn = graph.get("connection") or {}
        if conn.get("targetLow") is not None:
            target_low = target_to_mgdl(conn.get("targetLow"), conn.get("uom", uom)) or target_low
        if conn.get("targetHigh") is not None:
            target_high = target_to_mgdl(conn.get("targetHigh"), conn.get("uom", uom)) or target_high
        for entry in graph.get("graphData") or []:
            if not isinstance(entry, dict):
                continue
            epoch = measurement_epoch(entry)
            value = measurement_value(entry, uom)
            if epoch is None or value is None:
                continue
            series.append(
                {
                    "v": round(value, 1),
                    "t": epoch,
                    "tr": int(entry.get("TrendArrow") or 0),
                }
            )
        latest = conn.get("glucoseMeasurement")
        if isinstance(latest, dict):
            epoch = measurement_epoch(latest)
            value = measurement_value(latest, uom)
            if epoch is not None and value is not None:
                current = {"v": round(value, 1), "t": epoch, "tr": int(latest.get("TrendArrow") or 0)}

    if current is None:
        latest = connection.get("glucoseMeasurement")
        if isinstance(latest, dict):
            epoch = measurement_epoch(latest)
            value = measurement_value(latest, uom)
            if epoch is not None and value is not None:
                current = {"v": round(value, 1), "t": epoch, "tr": int(latest.get("TrendArrow") or 0)}

    sensor = connection.get("sensor") or {}
    activated = sensor.get("a")
    expires = None
    if isinstance(activated, (int, float)) and activated > 0:
        expires = int(activated) + 14 * 24 * 3600

    # A freshly accepted connection reports targetLow/targetHigh as 0 until the
    # primary app uploads its settings, which would classify every reading as
    # "high". Fall back to the clinical defaults instead.
    if not target_low:
        target_low = 70.0
    if not target_high:
        target_high = 180.0

    return {
        "sourceLabel": "LibreLinkUp (%s)" % (session.get("region") or "auto").upper(),
        "patientName": " ".join(
            part for part in [connection.get("firstName"), connection.get("lastName")] if part
        ),
        "targetLow": target_low,
        "targetHigh": target_high,
        "sensor": {
            "serial": sensor.get("sn") or "",
            "activatedAt": int(activated) if isinstance(activated, (int, float)) else None,
            "expiresAt": expires,
        },
        "current": current,
        "series": series,
    }


# --------------------------------------------------------------------------
# Nightscout
# --------------------------------------------------------------------------

NS_DIRECTIONS = {
    "doubleup": 5,
    "singleup": 5,
    "fortyfiveup": 4,
    "flat": 3,
    "fortyfivedown": 2,
    "singledown": 1,
    "doubledown": 1,
    "none": 0,
    "notcomputable": 0,
    "rateoutofrange": 0,
}


def fetch_nightscout(section, hours, verbose):
    base = (section.get("url") or "").strip().rstrip("/")
    if not base:
        raise ConfigError("nightscout.url is not set")
    if not base.startswith("http"):
        base = "https://" + base

    token = (section.get("token") or "").strip()
    token_type = (section.get("tokenType") or "secret").strip().lower()
    headers = {"Accept": "application/json"}
    query = {"count": max(288, int(hours * 60) + 60)}
    if token:
        if token_type == "secret":
            # Nightscout's api-secret header is the SHA1 of the API secret.
            headers["api-secret"] = hashlib.sha1(token.encode("utf-8")).hexdigest()
        else:
            query["token"] = token

    url = "%s/api/v1/entries.json?%s" % (base, urllib.parse.urlencode(query))
    status, payload, raw = http_json(url, "GET", headers, timeout=20)
    if status == 401 or status == 403:
        raise FetchError("auth", "Nightscout rejected the credentials (http %s)" % status)
    if not isinstance(payload, list):
        raise FetchError("protocol", "Nightscout returned an unexpected payload (http %s)" % status)

    series = []
    for entry in payload:
        if not isinstance(entry, dict) or entry.get("type", "sgv") != "sgv":
            continue
        value = entry.get("sgv")
        stamp = entry.get("date")
        if not isinstance(value, (int, float)) or not isinstance(stamp, (int, float)):
            continue
        series.append(
            {
                "v": float(value),
                "t": int(stamp / 1000),
                "tr": NS_DIRECTIONS.get(str(entry.get("direction") or "").replace(" ", "").lower(), 0),
            }
        )

    series.sort(key=lambda point: point["t"])
    current = series[-1] if series else None

    target_low = section.get("targetLow") or 70
    target_high = section.get("targetHigh") or 180

    return {
        "sourceLabel": "Nightscout",
        "patientName": section.get("patientName") or "",
        "targetLow": float(target_low),
        "targetHigh": float(target_high),
        "sensor": {"serial": "", "activatedAt": None, "expiresAt": None},
        "current": dict(current) if current else None,
        "series": series,
    }


# --------------------------------------------------------------------------
# mock
# --------------------------------------------------------------------------

def fetch_mock(section, hours, verbose):
    """Synthetic 24h trace: a flat-ish baseline with meal spikes.

    Exists so the widget can be developed and reviewed before real
    credentials are in place.
    """
    import math
    import random

    random.seed(int(section.get("seed") or 7))
    now = int(time.time())
    step = 300
    count = int(hours * 3600 / step)
    series = []
    for index in range(count):
        stamp = now - (count - index) * step
        hours_ago = (count - index) * step / 3600.0
        value = 108 + 14 * math.sin((hours_ago % 24) / 24.0 * 2 * math.pi)
        for meal in (2.1, 7.4, 13.2, 19.6):
            delta = meal - hours_ago
            if abs(delta) < 1.6:
                value += 78 * math.exp(-(delta * delta) / 0.5)
        value += random.uniform(-5, 5)
        value = max(48, min(286, value))
        series.append({"v": round(value, 1), "t": stamp, "tr": 3})

    for position in range(1, len(series)):
        slope = series[position]["v"] - series[position - 1]["v"]
        if slope > 12:
            series[position]["tr"] = 5
        elif slope > 4:
            series[position]["tr"] = 4
        elif slope < -12:
            series[position]["tr"] = 1
        elif slope < -4:
            series[position]["tr"] = 2
        else:
            series[position]["tr"] = 3

    return {
        "sourceLabel": "mock",
        "patientName": "Mock",
        "targetLow": 70.0,
        "targetHigh": 180.0,
        "sensor": {"serial": "MOCK0001", "activatedAt": now - 3 * 24 * 3600, "expiresAt": now + 11 * 24 * 3600},
        "current": dict(series[-1]),
        "series": series,
    }


# --------------------------------------------------------------------------
# account diagnostics
# --------------------------------------------------------------------------

def mask_email(value):
    text = str(value or "")
    if "@" not in text:
        return text[:2] + "***"
    name, domain = text.split("@", 1)
    return name[:2] + "***@" + domain


def run_whoami(config, args):
    """Report what this account is allowed to see, without reading glucose.

    Answers the only two questions that matter when the pipe is empty: who did
    I log in as, and am I following anybody?
    """
    section = dict(config.get("librelinkup") or {})
    if args.region:
        section["region"] = args.region
    if args.email:
        section["email"] = args.email

    session, host = llu_session(section, bool(args.debug))
    claims = session.get("claims") or jwt_claims(session.get("token"))
    result = {
        "ok": True,
        "whoami": True,
        "host": host,
        "region": session.get("region"),
        "role": claims.get("role"),
        "country": claims.get("country"),
        "name": (" ".join(
            part for part in [claims.get("firstName"), claims.get("lastName")] if part
        )).strip(),
        "email": mask_email(section.get("email")),
        "connections": [],
        "hint": "",
    }

    for conn in llu_connections(session, host):
        sensor = conn.get("sensor") or {}
        latest = conn.get("glucoseMeasurement") or {}
        result["connections"].append({
            "patientId": conn.get("patientId"),
            "country": conn.get("country"),
            "uom": conn.get("uom"),
            "targetLow": conn.get("targetLow"),
            "targetHigh": conn.get("targetHigh"),
            "sensorSerial": sensor.get("sn"),
            "latest": latest.get("FactoryTimestamp") or latest.get("Timestamp"),
        })

    if not result["connections"]:
        result["ok"] = False
        result["hint"] = (
            "no follower link for this account: invite an email from 瞬感宝 共享/数据共享 "
            "and accept it in 瞬感通"
        )
    return result


# --------------------------------------------------------------------------
# payload plumbing
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# login attempt guard
# --------------------------------------------------------------------------

GUARD_MAX_FAILURES = 3
GUARD_COOLDOWN_SECONDS = 1800


def login_guard_check(path):
    """Refuse to keep hammering the login endpoint with known-bad credentials."""
    state = load_json_file(path) or {}
    blocked_until = float(state.get("blockedUntil") or 0)
    if blocked_until > time.time():
        minutes = int((blocked_until - time.time()) / 60) + 1
        raise FetchError(
            "cooldown",
            "login failed %s times in a row; pausing attempts for ~%d more minutes. "
            "Fix the account in the config file, then delete %s to retry immediately."
            % (state.get("failures"), minutes, path),
        )
    return state


def login_guard_fail(path, state):
    failures = int(state.get("failures") or 0) + 1
    updated = {"failures": failures, "lastFailureAt": int(time.time())}
    if failures >= GUARD_MAX_FAILURES:
        updated["blockedUntil"] = int(time.time()) + GUARD_COOLDOWN_SECONDS
    write_json_file(path, updated)
    return updated


def login_guard_clear(path):
    if os.path.exists(path):
        try:
            os.remove(path)
        except OSError:
            pass


def load_json_file(path):
    path = expand(path)
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (ValueError, OSError):
        return None


def write_json_file(path, payload):
    path = expand(path)
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(payload, handle)
        # These files hold a bearer token and health data; keep them private.
        try:
            os.chmod(temporary, 0o600)
        except OSError:
            pass
        os.replace(temporary, path)
    except OSError as exc:
        log("could not write cache %s: %s" % (path, exc))


def trend_from_rate(rate):
    """Map a mg/dL-per-minute slope onto Libre's 1..5 arrow codes."""
    if rate > 3:
        return 5   # rising quickly
    if rate > 2:
        return 4   # rising
    if rate >= -2:
        return 3   # stable
    if rate >= -3:
        return 2   # falling
    return 1       # falling quickly


def fill_missing_trends(points):
    """Derive trend arrows where the API did not supply one.

    The LibreLinkUp graph endpoint returns `TrendArrow` as 0 for every point
    (only the current reading carries a real one, and even that is often 0), so
    without this the bar would show a flat dot forever.
    """
    for index in range(1, len(points)):
        if points[index].get("tr"):
            continue
        minutes = (points[index]["t"] - points[index - 1]["t"]) / 60.0
        if minutes <= 0:
            continue
        points[index]["tr"] = trend_from_rate((points[index]["v"] - points[index - 1]["v"]) / minutes)
    return points


def build_payload(config, args):
    source = (args.source or config.get("source") or "librelinkup").strip().lower()
    hours = float(args.hours or config.get("historyHours") or 24)
    verbose = bool(args.debug)

    if source == "librelinkup":
        section = dict(config.get("librelinkup") or {})
        if args.region:
            section["region"] = args.region
        if args.email:
            section["email"] = args.email
        body = fetch_librelinkup(section, hours, verbose)
    elif source == "nightscout":
        body = fetch_nightscout(dict(config.get("nightscout") or {}), hours, verbose)
    elif source == "mock":
        body = fetch_mock(dict(config.get("mock") or {}), hours, verbose)
    else:
        raise ConfigError("unknown source %r (expected librelinkup, nightscout or mock)" % source)

    now = int(time.time())
    series = body.get("series") or []
    cutoff = now - int(hours * 3600)
    series = sorted((point for point in series if point["t"] >= cutoff), key=lambda point: point["t"])

    # Collapse duplicate timestamps (the graph can repeat the newest reading).
    deduped = []
    for point in series:
        if deduped and deduped[-1]["t"] == point["t"]:
            deduped[-1] = point
        else:
            deduped.append(point)

    fill_missing_trends(deduped)

    current = body.get("current")
    if current is None and deduped:
        current = dict(deduped[-1])
    if current is not None:
        if not current.get("tr") and len(deduped) > 1:
            current["tr"] = deduped[-1].get("tr") or 0
        current["ageSec"] = max(0, now - int(current["t"]))

    return {
        "ok": True,
        "source": source,
        # Provenance of the numbers on screen. On the success path it is the
        # same as `source`; on a failed poll the series we keep showing may have
        # come from an earlier, different source.
        "seriesSource": source,
        "sourceLabel": body.get("sourceLabel") or source,
        "fetchedAt": now,
        "unit": "mg/dL",
        "patientName": body.get("patientName") or "",
        "targetLow": body.get("targetLow"),
        "targetHigh": body.get("targetHigh"),
        "sensor": body.get("sensor") or {},
        "current": current,
        "series": deduped,
        "historyHours": hours,
        "error": None,
        "code": None,
    }


def error_payload(source, code, message, previous=None):
    payload = {
        "ok": False,
        "source": source,
        "sourceLabel": (previous or {}).get("sourceLabel") or source,
        "fetchedAt": int(time.time()),
        "unit": "mg/dL",
        "patientName": "",
        "targetLow": None,
        "targetHigh": None,
        "sensor": {},
        "current": None,
        "series": [],
        "error": message,
        "code": code,
        # Keep the last good series so the chart does not blink empty on a
        # single failed poll.
        "stale": True,
    }
    if previous and previous.get("series"):
        for key in ("sourceLabel", "patientName", "targetLow", "targetHigh", "sensor", "current", "series"):
            payload[key] = previous.get(key)
        payload["seriesSource"] = previous.get("seriesSource") or previous.get("source")
        payload["error"] = message
        payload["code"] = code
        payload["ok"] = False
    else:
        payload["seriesSource"] = None
    return payload


def main(argv):
    parser = argparse.ArgumentParser(description="Fetch CGM data for the Omarchy glucose widget.")
    parser.add_argument("--config", default=os.environ.get("GLUCOSE_CONFIG", DEFAULT_CONFIG))
    parser.add_argument("--cache", default=os.environ.get("GLUCOSE_CACHE", DEFAULT_CACHE))
    parser.add_argument("--source", default=None, help="librelinkup | nightscout | mock")
    parser.add_argument("--hours", default=None, help="history window to request")
    parser.add_argument("--region", default=None, help="override LibreLinkUp region")
    parser.add_argument("--email", default=None, help="override LibreLinkUp email")
    parser.add_argument("--no-cache", action="store_true")
    parser.add_argument("--whoami", action="store_true",
                        help="report the account role and follower links, then exit")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args(argv)

    if args.whoami:
        try:
            config = load_config(args.config)
            payload = run_whoami(config, args)
        except ConfigError as exc:
            payload = {"ok": False, "whoami": True, "error": str(exc), "code": "config"}
        except FetchError as exc:
            payload = {"ok": False, "whoami": True, "error": str(exc), "code": exc.code}
        json.dump(payload, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0 if payload.get("ok") else 1

    cache_path = expand(args.cache)
    previous = load_json_file(cache_path)

    try:
        config = load_config(args.config, required=bool(args.source != "mock"))
        payload = build_payload(config, args)
    except ConfigError as exc:
        payload = error_payload(args.source or "unknown", "config", str(exc), previous)
    except FetchError as exc:
        payload = error_payload(args.source or "unknown", exc.code, str(exc), previous)
    except Exception as exc:  # noqa: BLE001 - the widget must always get JSON
        if args.debug:
            import traceback

            traceback.print_exc()
        payload = error_payload(args.source or "unknown", "unknown", "%s: %s" % (type(exc).__name__, exc), previous)

    if not args.no_cache:
        write_json_file(cache_path, payload)

    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if payload.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
