export type Preference = {
  secret: string;
  enabled: boolean;
  pending: boolean;
  token?: string;
};

export type Dependencies = {
  load: () => Promise<Preference | null>;
  save: (value: Preference) => Promise<void>;
  secret: () => string;
  permission: (request: boolean) => Promise<boolean>;
  pushToken: () => Promise<string>;
  update: (value: Preference) => Promise<void>;
};

/** Serialize permission prompts, token rotation, resume, and toggle changes. */
export class Subscription {
  value: Preference | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  constructor(private deps: Dependencies, private changed: () => void = () => {}) {}

  private enqueue(work: () => Promise<void>) {
    const task = this.queue.then(work);
    this.queue = task.catch(() => {});
    return task;
  }

  private async persist(value: Preference) {
    await this.deps.save(value);
    this.value = value;
    this.changed();
  }

  private async load() {
    if (!this.value) {
      const saved = await this.deps.load();
      await this.persist(saved ?? {
        secret: this.deps.secret(), enabled: false, pending: false,
      });
    }
  }

  private async synchronize() {
    let value = this.value!;
    if (value.enabled) {
      if (!await this.deps.permission(false)) {
        await this.persist({ ...value, enabled: false, pending: true });
      } else {
        // Refresh Expo tokens on resume and whenever the native token changes.
        const token = await this.deps.pushToken();
        await this.persist({ ...value, token, pending: true });
      }
    }
    value = this.value!;
    if (value.pending) {
      await this.deps.update(value);
      await this.persist({ ...value, pending: false });
    }
  }

  refresh() {
    return this.enqueue(async () => {
      await this.load();
      await this.synchronize();
    });
  }

  setEnabled(enabled: boolean) {
    return this.enqueue(async () => {
      await this.load();
      if (enabled && !await this.deps.permission(true)) {
        // Also revoke a stale registration if permissions were changed in Settings.
        if (this.value!.enabled || this.value!.token) {
          await this.persist({ ...this.value!, enabled: false, pending: true });
          await this.synchronize();
        }
        throw new Error('Allow NewsBot notifications in your phone’s Settings, then enable this switch.');
      }
      // Persist intent before network work; a lost response is reconciled on restart.
      await this.persist({ ...this.value!, enabled, pending: true });
      await this.synchronize();
    });
  }
}

/** Only present the remote notification; never schedule a second local copy. */
export class ForegroundDedup {
  private seen = new Set<string>();
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private load: () => Promise<string[]>, private save: (ids: string[]) => Promise<void>) {}
  accept(id: unknown, enabled: boolean): Promise<boolean> {
    const task = this.queue.then(async () => {
      if (!enabled || (typeof id !== 'number' && typeof id !== 'string')) return false;
      if (this.seen.size === 0) this.seen = new Set(await this.load());
      const key = String(id);
      if (this.seen.has(key)) return false;
      this.seen.add(key);
      this.seen = new Set([...this.seen].slice(-100));
      await this.save([...this.seen]);
      return true;
    });
    this.queue = task.catch(() => {});
    return task;
  }
}
