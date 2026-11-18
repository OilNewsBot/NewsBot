import type { DevicePushToken } from 'expo-notifications';

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
  pushToken: (deviceToken?: DevicePushToken) => Promise<string>;
  update: (value: Preference) => Promise<void>;
};

/** Serialize permission prompts, token rotation, resume, and toggle changes. */
export class Subscription {
  value: Preference | null = null;
  private queue: Promise<unknown> = Promise.resolve();

  private disableVersion = 0;
  private cancelLookup?: () => void;

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
      if (saved) {
        this.value = saved;
        this.changed();
      } else {
        await this.persist({ secret: this.deps.secret(), enabled: false, pending: false });
      }
    }
  }

  // Expo has no cancellation hook. A late result belongs to the old preference.
  private async lookup(deviceToken?: DevicePushToken): Promise<string | undefined> {
    let timer: ReturnType<typeof setTimeout> | undefined;
    const interrupted = new Promise<undefined>((resolve, reject) => {
      this.cancelLookup = () => resolve(undefined);
      timer = setTimeout(() => reject(new Error('Expo token lookup timed out.')), 15_000);
    });
    try {
      return await Promise.race([this.deps.pushToken(deviceToken), interrupted]);
    } finally {
      clearTimeout(timer);
      this.cancelLookup = undefined;
    }
  }

  private async synchronize(version: number, deviceToken?: DevicePushToken) {
    let value = this.value!;
    if (value.enabled) {
      const allowed = await this.deps.permission(false);
      if (version !== this.disableVersion) return;
      if (!allowed) {
        await this.persist({ ...value, enabled: false, pending: true });
      } else {
        let token: string | undefined;
        try {
          token = await this.lookup(deviceToken);
        } catch (error) {
          if (version !== this.disableVersion) return;
          if (!value.pending) await this.persist({ ...value, pending: true });
          throw error;
        }
        if (token === undefined || version !== this.disableVersion) return;
        if (token !== value.token) await this.persist({ ...value, token, pending: true });
      }
    }

    value = this.value!;
    if (value.pending && version === this.disableVersion) {
      await this.deps.update(value);
      await this.persist({ ...value, pending: false });
    }
  }

  refresh(deviceToken?: DevicePushToken) {
    const version = this.disableVersion;
    return this.enqueue(async () => {
      await this.load();
      if (version === this.disableVersion) await this.synchronize(version, deviceToken);
    });
  }

  retryPending() {
    if (this.value && !this.value.pending) return Promise.resolve();
    return this.refresh();
  }

  setEnabled(enabled: boolean) {
    if (!enabled) {
      this.disableVersion++;
      this.cancelLookup?.();
    }
    const version = this.disableVersion;
    return this.enqueue(async () => {
      await this.load();
      if (version !== this.disableVersion) return;
      const allowed = !enabled || await this.deps.permission(true);
      if (version !== this.disableVersion) return;
      if (!allowed) {
        if (this.value!.enabled || this.value!.token) {
          await this.persist({ ...this.value!, enabled: false, pending: true });
          await this.synchronize(version);
        }
        throw new Error('Allow NewsBot notifications in your phone’s Settings, then enable this switch.');
      }
      await this.persist({ ...this.value!, enabled, pending: true });
      await this.synchronize(version);
    });
  }
}

/** Only present the remote notification; never schedule a second local copy. */
export class ForegroundDedup {
  private seen = new Set<string>();
  private needsSave = false;
  private queue: Promise<unknown> = Promise.resolve();
  constructor(private load: () => Promise<string[]>, private save: (ids: string[]) => Promise<void>) {}
  accept(id: unknown, enabled: boolean): Promise<boolean> {
    const task = this.queue.then(async () => {
      if (!enabled || (typeof id !== 'number' && typeof id !== 'string')) return false;
      if (this.seen.size === 0) this.seen = new Set(await this.load());
      const key = String(id);
      const alreadyShown = this.seen.has(key);
      if (alreadyShown && !this.needsSave) return false;
      if (!alreadyShown) this.seen = new Set([...this.seen, key].slice(-100));
      try {
        await this.save([...this.seen]);
        this.needsSave = false;
      } catch {
        // The OS may deliver this alert only once. Show it now and retry the
        // durable checkpoint on the next receipt, including duplicate receipts.
        this.needsSave = true;
      }
      return !alreadyShown;
    });
    this.queue = task.catch(() => {});
    return task;
  }
}
