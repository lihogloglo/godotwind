"""Per-channel summary store — agents write, everyone reads."""

import json
import time
import threading
from pathlib import Path

MAX_CHARS = 1000


class SummaryStore:
    def __init__(self, path: str):
        self._path = Path(path)
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._summaries: dict[str, dict] = {}  # channel → summary dict
        self._lock = threading.Lock()
        self._load()

    def _load(self):
        if not self._path.exists():
            return
        try:
            raw = json.loads(self._path.read_text("utf-8"))
            if isinstance(raw, dict):
                self._summaries = raw
        except (json.JSONDecodeError, KeyError):
            self._summaries = {}

    def _save(self):
        self._path.write_text(
            json.dumps(self._summaries, indent=2, ensure_ascii=False) + "\n",
            "utf-8",
        )

    def get(self, channel: str) -> dict | None:
        with self._lock:
            entry = self._summaries.get(channel)
            return dict(entry) if entry else None

    def get_all(self) -> dict:
        with self._lock:
            return {ch: dict(s) for ch, s in self._summaries.items()}

    def write(self, channel: str, text: str, author: str, message_id: int = 0) -> dict | None:
        text = text.strip()
        if not text:
            return None
        if len(text) > MAX_CHARS:
            return None  # Caller should inform the agent
        with self._lock:
            entry = {
                "text": text,
                "author": author,
                "updated_at": time.time(),
                "message_id": message_id,
            }
            self._summaries[channel] = entry
            self._save()
            return dict(entry)

    def delete(self, channel: str) -> bool:
        with self._lock:
            if channel in self._summaries:
                del self._summaries[channel]
                self._save()
                return True
            return False
