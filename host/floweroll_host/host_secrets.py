from __future__ import annotations

import os
import subprocess
import sys
from typing import Optional


AMAP_KEYCHAIN_SERVICE = "com.maxenceyu.floweroll.host.amap"
AMAP_KEYCHAIN_ACCOUNT = "AMAP_MAPS_API_KEY"
FLYAI_KEYCHAIN_SERVICE = "Floweroll Host"
FLYAI_KEYCHAIN_ACCOUNT = "FLYAI_API_KEY"
MEM0_KEYCHAIN_SERVICE = "com.maxenceyu.floweroll.host.mem0"
MEM0_KEYCHAIN_ACCOUNT = "MEM0_API_KEY"


def read_macos_keychain_secret(
    *,
    service: str,
    account: str,
    timeout_seconds: float = 3.0,
) -> Optional[str]:
    """Read one generic-password value without logging or persisting it elsewhere."""

    if sys.platform != "darwin":
        return None
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-a",
                account,
                "-s",
                service,
                "-w",
            ],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    secret = result.stdout.rstrip("\r\n")
    return secret if secret else None


def hydrate_amap_key_from_host_secret_store() -> Optional[str]:
    """Populate the process-only Amap env var, preferring an explicit env value.

    Returns the source name for diagnostics (``environment``/``keychain``) or
    ``None`` when no key is configured. The secret itself is never returned.
    """

    configured = os.environ.get("AMAP_MAPS_API_KEY", "").strip()
    if configured:
        return "environment"
    secret = read_macos_keychain_secret(
        service=AMAP_KEYCHAIN_SERVICE,
        account=AMAP_KEYCHAIN_ACCOUNT,
    )
    if not secret:
        return None
    os.environ["AMAP_MAPS_API_KEY"] = secret
    return "keychain"

def hydrate_flyai_key_from_host_secret_store() -> Optional[str]:
    """Populate the process-only FlyAI env var without exposing the secret."""

    configured = os.environ.get("FLYAI_API_KEY", "").strip()
    if configured:
        return "environment"
    secret = read_macos_keychain_secret(
        service=FLYAI_KEYCHAIN_SERVICE,
        account=FLYAI_KEYCHAIN_ACCOUNT,
    )
    if not secret:
        return None
    os.environ["FLYAI_API_KEY"] = secret
    return "keychain"



def hydrate_mem0_key_from_host_secret_store() -> Optional[str]:
    """Populate MEM0_API_KEY from env, Keychain, or Mem0 CLI config.

    The Mem0 CLI owns ``~/.mem0/config.json``. We read only that exact file
    as a last-resort secret source and never copy the key into project files.
    Returns only the source label, never the secret value.
    """

    configured = os.environ.get("MEM0_API_KEY", "").strip()
    if configured:
        return "environment"

    secret = read_macos_keychain_secret(
        service=MEM0_KEYCHAIN_SERVICE,
        account=MEM0_KEYCHAIN_ACCOUNT,
    )
    if secret:
        os.environ["MEM0_API_KEY"] = secret
        return "keychain"

    try:
        import json
        from pathlib import Path

        config_path = Path.home() / ".mem0" / "config.json"
        payload = json.loads(config_path.read_text(encoding="utf-8"))
        platform = payload.get("platform") if isinstance(payload, dict) else None
        candidate = platform.get("api_key") if isinstance(platform, dict) else None
        if isinstance(candidate, str) and candidate.strip():
            os.environ["MEM0_API_KEY"] = candidate.strip()
            return "mem0-cli-config"
    except (OSError, ValueError, TypeError):
        pass
    return None
