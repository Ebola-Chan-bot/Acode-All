"""Minimal GitHub Copilot PoC for Acode Phase 0.

This script validates the special Copilot authentication and chat flow that
cannot be treated like a standard OpenAI-compatible provider.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request
from typing import Any


COPILOT_CLIENT_ID = "Iv1.b507a08c87ecfe98"
USER_AGENT = "GithubCopilot/1.155.0"
TOKEN_CACHE_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    ".copilot_oauth_token.json",
)


def post_json(url: str, data: dict[str, Any] | None, headers: dict[str, str] | None = None) -> dict[str, Any]:
    request_headers = {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    if headers:
        request_headers.update(headers)
    body = json.dumps(data).encode("utf-8") if data is not None else None
    request = urllib.request.Request(url, data=body, headers=request_headers)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read())


def get_json(url: str, headers: dict[str, str] | None = None) -> Any:
    request_headers = {
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    if headers:
        request_headers.update(headers)
    request = urllib.request.Request(url, headers=request_headers)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read())


def load_cached_oauth_token() -> str | None:
    if not os.path.exists(TOKEN_CACHE_FILE):
        return None
    with open(TOKEN_CACHE_FILE, "r", encoding="utf-8") as file:
        data = json.load(file)
    return data.get("access_token")


def save_oauth_token(token: str) -> None:
    with open(TOKEN_CACHE_FILE, "w", encoding="utf-8") as file:
        json.dump({"access_token": token}, file)


def device_code_flow() -> str:
    response = post_json(
        "https://github.com/login/device/code",
        {"client_id": COPILOT_CLIENT_ID, "scope": "read:user"},
    )
    device_code = response["device_code"]
    user_code = response["user_code"]
    verification_uri = response["verification_uri"]
    interval = response.get("interval", 5)
    expires_in = response.get("expires_in", 900)

    print("Visit:", verification_uri)
    print("Code :", user_code)
    print("Waiting for GitHub authorization...")

    deadline = time.time() + expires_in
    while time.time() < deadline:
        time.sleep(interval)
        token_response = post_json(
            "https://github.com/login/oauth/access_token",
            {
                "client_id": COPILOT_CLIENT_ID,
                "device_code": device_code,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            },
        )

        access_token = token_response.get("access_token")
        if access_token:
            save_oauth_token(access_token)
            return access_token

        error = token_response.get("error")
        if error == "authorization_pending":
            print(".", end="", flush=True)
            continue
        if error == "slow_down":
            interval += 5
            continue
        if error == "expired_token":
            raise RuntimeError("GitHub device code expired before authorization completed")
        raise RuntimeError(f"Unexpected GitHub OAuth error: {token_response}")

    raise RuntimeError("Timed out waiting for GitHub device authorization")


def get_copilot_session_token(oauth_token: str) -> dict[str, Any]:
    return get_json(
        "https://api.github.com/copilot_internal/v2/token",
        headers={"Authorization": f"token {oauth_token}"},
    )


def list_models(copilot_token: str) -> list[dict[str, Any]]:
    data = get_json(
        "https://api.githubcopilot.com/models",
        headers={
            "Authorization": f"Bearer {copilot_token}",
            "Copilot-Integration-Id": "vscode-chat",
        },
    )
    if isinstance(data, list):
        return data
    return data.get("data", data.get("models", []))


def run_chat(copilot_token: str, model: str, prompt: str) -> dict[str, Any]:
    return post_json(
        "https://api.githubcopilot.com/chat/completions",
        {
            "messages": [{"role": "user", "content": prompt}],
            "model": model,
            "max_tokens": 400,
            "temperature": 0.1,
            "stream": False,
        },
        headers={
            "Authorization": f"Bearer {copilot_token}",
            "Copilot-Integration-Id": "vscode-chat",
        },
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="GitHub Copilot Phase 0 PoC")
    parser.add_argument(
        "--prompt",
        default="Summarize why Copilot needs a dedicated provider adapter in Acode in 3 bullet points.",
    )
    args = parser.parse_args()

    try:
        oauth_token = load_cached_oauth_token() or device_code_flow()
        token_payload = get_copilot_session_token(oauth_token)
        copilot_token = token_payload.get("token")
        if not copilot_token:
            raise RuntimeError(f"Missing Copilot session token: {token_payload}")

        models = list_models(copilot_token)
        if not models:
            raise RuntimeError("No Copilot models returned")

        preferred_model = None
        for model in models:
            model_id = model.get("id", "")
            if "claude" in model_id.lower():
                preferred_model = model_id
                break
        if not preferred_model:
            preferred_model = models[0].get("id")

        response = run_chat(copilot_token, preferred_model, args.prompt)
        print(json.dumps({
            "selected_model": preferred_model,
            "token_expires_at": token_payload.get("expires_at"),
            "response": response,
        }, ensure_ascii=False, indent=2))
        return 0
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        print(f"HTTP error: {error.code} {error.reason}\n{body}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
	raise SystemExit(main())