// session.ts — an agent session tree with branching, as stored on disk.
export type EntryType = 'message' | 'model_change' | 'compaction' | 'label';

export interface Entry {
  readonly id: string;
  readonly parentId: string | null;
  readonly type: EntryType;
  readonly timestamp: number;
  readonly payload: Record<string, unknown>;
}

export class SessionTree {
  private readonly entries = new Map<string, Entry>();
  private head: string | null = null;

  append(type: EntryType, payload: Record<string, unknown>): Entry {
    const entry: Entry = { id: crypto.randomUUID(), parentId: this.head, type, timestamp: Date.now(), payload };
    this.entries.set(entry.id, entry);
    this.head = entry.id;
    return entry;
  }

  branch(fromId: string): void {
    if (!this.entries.has(fromId)) {
      throw new Error(`Unknown entry ${fromId}`);
    }
    this.head = fromId;
  }

  *path(): Generator<Entry> {
    const chain: Entry[] = [];
    for (let id = this.head; id !== null; id = this.entries.get(id)?.parentId ?? null) {
      chain.push(this.entries.get(id)!);
    }
    yield* chain.reverse();
  }

  toJSONL(): string {
    return [...this.entries.values()].map((entry) => JSON.stringify(entry)).join('\n');
  }
}
