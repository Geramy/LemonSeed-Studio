// palette.js — builds the command palette's fuzzy-ranked result list.
const PREFIXES = new Map([
  ['>', 'command'],
  ['@', 'symbol'],
  ['#', 'workspace-symbol'],
  [':', 'line'],
  ['?', 'ask'],
]);

export function parseQuery(input) {
  const prefix = PREFIXES.get(input[0]);
  return prefix ? { kind: prefix, text: input.slice(1).trim() } : { kind: 'file', text: input.trim() };
}

export function score(candidate, query) {
  let total = 0;
  let position = 0;
  for (const char of query.toLowerCase()) {
    const found = candidate.toLowerCase().indexOf(char, position);
    if (found === -1) return null;
    total += found === position ? 15 : 5;
    position = found + 1;
  }
  return total - candidate.length * 0.1;
}

export async function rank(items, input, { recent = [] } = {}) {
  const { kind, text } = parseQuery(input);
  const scored = items
    .filter((item) => item.kind === kind)
    .map((item) => ({ item, score: score(item.title, text) }))
    .filter(({ score }) => score !== null);
  scored.sort((a, b) => b.score - a.score || recent.indexOf(a.item.id) - recent.indexOf(b.item.id));
  return scored.slice(0, 50).map(({ item }) => item);
}
