"""Shared config loader — merges config.toml + config.local.toml.

Used by run.py, wrapper.py, and wrapper_api.py so the server and all
wrappers see the same agent definitions.
"""

import tomllib
from pathlib import Path

ROOT = Path(__file__).parent


def load_config(root: Path | None = None) -> dict:
    """Load config.toml and merge config.local.toml if it exists.

    config.local.toml is gitignored and intended for user-specific agents
    (e.g. local LLM endpoints) that shouldn't be committed.
    Only the [agents] section is merged — local entries are added alongside
    (not replacing) the agents defined in config.toml.
    """
    root = root or ROOT
    config_path = root / "config.toml"

    with open(config_path, "rb") as f:
        config = tomllib.load(f)

    local_path = root / "config.local.toml"
    if local_path.exists():
        with open(local_path, "rb") as f:
            local = tomllib.load(f)
        
        # Merge [agents] section — local agents are added ONLY if they don't already exist.
        # This protects the "holy trinity" (claude, codex, gemini) from being overridden.
        local_agents = local.get("agents", {})
        config_agents = config.setdefault("agents", {})
        for name, agent_cfg in local_agents.items():
            if name not in config_agents:
                config_agents[name] = agent_cfg
            else:
                print(f"  Warning: Ignoring local agent '{name}' (already defined in config.toml)")

    return config
