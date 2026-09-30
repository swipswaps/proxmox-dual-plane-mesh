"""Local Tool: Deduplication Cache."""

import hashlib
import time
from typing import Dict


class DeduplicationCache:
    def __init__(self, ttl_seconds: int = 300):
        self.ttl = ttl_seconds
        self._cache: Dict[str, float] = {}

    def _generate_hash(self, content: str) -> str:
        return hashlib.sha256(content.encode('utf-8')).hexdigest()

    def is_duplicate(self, content: str) -> bool:
        now = time.time()
        content_hash = self._generate_hash(content)
        self._cache = {k: v for k, v in self._cache.items() if (now - v) < self.ttl}
        if content_hash in self._cache:
            return True
        self._cache[content_hash] = now
        return False
