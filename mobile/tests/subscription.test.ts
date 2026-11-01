import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ForegroundDedup, Subscription, type Preference, type Dependencies } from '../src/subscription';

function setup(saved: Preference | null = null) {
  const state = { saved, permission: true, online: true, token: 'ExpoPushToken[first]', prompts: 0, sent: [] as Preference[] };
  const deps: Dependencies = {
    load: async () => state.saved,
    save: async value => { state.saved = { ...value }; },
    secret: () => 'a'.repeat(64),
    permission: async request => { if (request) state.prompts++; return state.permission; },
    pushToken: async () => state.token,
    update: async value => {
      if (!state.online) throw new Error('offline');
      state.sent.push({ ...value });
    },
  };
  return { state, deps, app: new Subscription(deps) };
}

test('first launch is off, never prompts, and does not register', async () => {
  const { app, state } = setup();
  await app.refresh();
  assert.equal(app.value?.enabled, false);
  assert.equal(state.prompts, 0);
  assert.equal(state.sent.length, 0);
});

test('enable persists across launches and refresh rotates token with same identity', async () => {
  const { app, state, deps } = setup();
  await app.setEnabled(true);
  assert.equal(state.saved?.pending, false);
  state.token = 'ExpoPushToken[rotated]';
  const restarted = new Subscription(deps);
  await restarted.refresh();
  assert.equal(restarted.value?.enabled, true);
  assert.equal(state.sent[1].token, state.token);
  assert.equal(state.sent[0].secret, state.sent[1].secret);
  assert.equal(state.prompts, 1);
});

test('permission denial leaves switch off without registration', async () => {
  const { app, state } = setup();
  state.permission = false;
  await assert.rejects(app.setEnabled(true), /Settings/);
  assert.equal(app.value?.enabled, false);
  assert.equal(state.sent.length, 0);
});

test('revoked permission disables backend on resume without prompting', async () => {
  const { app, state } = setup();
  await app.setEnabled(true);
  state.permission = false;
  await app.refresh();
  assert.equal(state.sent.at(-1)?.enabled, false);
  assert.equal(app.value?.enabled, false);
  assert.equal(state.prompts, 1);
});

test('offline disable persists intent and retries after process restart', async () => {
  const { app, state, deps } = setup();
  await app.setEnabled(true);
  state.online = false;
  await assert.rejects(app.setEnabled(false), /offline/);
  assert.equal(state.saved?.enabled, false);
  assert.equal(state.saved?.pending, true);
  state.online = true;
  const restarted = new Subscription(deps);
  await restarted.refresh();
  assert.equal(state.sent.at(-1)?.enabled, false);
  assert.equal(restarted.value?.pending, false);
});

test('enable failure is visibly pending and reconciles', async () => {
  const { app, state } = setup();
  state.online = false;
  await assert.rejects(app.setEnabled(true));
  assert.equal(state.saved?.pending, true);
  state.online = true;
  await app.refresh();
  assert.equal(app.value?.pending, false);
  assert.equal(state.sent.at(-1)?.enabled, true);
});

test('rapid enable then disable cannot finish with stale enable', async () => {
  const { app, state } = setup();
  await Promise.all([app.setEnabled(true), app.setEnabled(false)]);
  assert.deepEqual(state.sent.map(value => value.enabled), [true, false]);
  assert.equal(state.saved?.enabled, false);
});

test('token failure cannot prevent disabling', async () => {
  const { app, deps, state } = setup();
  await app.setEnabled(true);
  deps.pushToken = async () => { throw new Error('Expo offline'); };
  await app.setEnabled(false);
  assert.equal(state.sent.at(-1)?.enabled, false);
});

test('foreground dedup survives restart and simultaneous deliveries', async () => {
  let ids: string[] = [];
  const load = async () => ids;
  const save = async (next: string[]) => { ids = next; };
  const dedup = new ForegroundDedup(load, save);
  assert.deepEqual(await Promise.all([dedup.accept(7, true), dedup.accept(7, true)]), [true, false]);
  assert.equal(await new ForegroundDedup(load, save).accept('7', true), false);
  assert.equal(await dedup.accept(8, false), false);
  assert.equal(await dedup.accept(8, true), true);
});
