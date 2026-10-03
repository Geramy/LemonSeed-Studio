"""Byte-pair tokenizer used to estimate prompt sizes before sending them to the engine."""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

PRETOKENIZE = re.compile(r"""'s|'t|'re|'ve|'m|'ll|'d| ?\w+| ?\d+| ?[^\s\w\d]+|\s+""")


@dataclass
class Tokenizer:
    merges: dict[tuple[str, str], int]
    vocab: dict[str, int] = field(default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> "Tokenizer":
        data = json.loads(path.read_text(encoding="utf-8"))
        merges = {tuple(pair.split(" ")): rank for rank, pair in enumerate(data["merges"])}
        return cls(merges=merges, vocab=data["vocab"])

    def _bpe(self, word: str) -> list[str]:
        parts = list(word)
        while len(parts) > 1:
            ranked = [(self.merges.get(pair, float("inf")), i) for i, pair in enumerate(zip(parts, parts[1:]))]
            rank, index = min(ranked)
            if rank == float("inf"):
                break
            parts[index:index + 2] = [parts[index] + parts[index + 1]]
        return parts

    def encode(self, text: str) -> list[int]:
        tokens: list[int] = []
        for match in PRETOKENIZE.finditer(text):
            for piece in self._bpe(match.group()):
                tokens.append(self.vocab.get(piece, 0))
        return tokens


if __name__ == "__main__":
    tokenizer = Tokenizer.load(Path("tokenizer.json"))
    print(f"{len(tokenizer.encode('Hello, iPad!'))} tokens")
