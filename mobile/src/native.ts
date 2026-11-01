import { Platform } from 'react-native';
import Constants from 'expo-constants';
import * as Crypto from 'expo-crypto';
import * as Notifications from 'expo-notifications';
import * as SecureStore from 'expo-secure-store';
import { ForegroundDedup, Subscription, type Preference } from './subscription';

const storageKey = 'newsbot.subscription.v1';
const seenKey = 'newsbot.seen.v1';
const listeners = new Set<() => void>();

export function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}

export const subscription = new Subscription({
  load: async () => {
    const raw = await SecureStore.getItemAsync(storageKey);
    return raw ? JSON.parse(raw) as Preference : null;
  },
  save: value => SecureStore.setItemAsync(storageKey, JSON.stringify(value)),
  secret: () => Array.from(Crypto.getRandomBytes(32), b => b.toString(16).padStart(2, '0')).join(''),
  permission: async request => {
    // Android 13's permission prompt requires a notification channel first.
    if (Platform.OS === 'android') {
      await Notifications.setNotificationChannelAsync('newsbot', {
        name: 'NewsBot', importance: Notifications.AndroidImportance.HIGH, sound: 'default',
      });
    }
    let permission = await Notifications.getPermissionsAsync();
    const allowed = () => permission.granted ||
      permission.ios?.status === Notifications.IosAuthorizationStatus.PROVISIONAL;
    if (!allowed() && request && permission.canAskAgain) {
      permission = await Notifications.requestPermissionsAsync();
    }
    if (Platform.OS === 'android' && allowed()) {
      const channel = await Notifications.getNotificationChannelAsync('newsbot');
      if (channel?.importance === Notifications.AndroidImportance.NONE) return false;
    }
    return allowed();
  },
  pushToken: async () => {
    const projectId = Constants.expoConfig?.extra?.eas?.projectId ?? Constants.easConfig?.projectId;
    if (!projectId) throw new Error('This build needs an Expo EAS project ID. See mobile/README.md.');
    return (await Notifications.getExpoPushTokenAsync({ projectId })).data;
  },
  update: async value => {
    const base = process.env.EXPO_PUBLIC_API_URL?.replace(/\/$/, '');
    if (!base?.startsWith('https://')) {
      throw new Error('This build needs an HTTPS NewsBot API URL. See mobile/README.md.');
    }
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(`${base}/mobile/subscription`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${value.secret}` },
        body: JSON.stringify({ enabled: value.enabled, ...(value.enabled ? { token: value.token } : {}) }),
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`NewsBot could not save your setting (HTTP ${response.status}).`);
    } finally { clearTimeout(timer); }
  },
}, () => listeners.forEach(listener => listener()));

const dedup = new ForegroundDedup(
  async () => JSON.parse(await SecureStore.getItemAsync(seenKey) ?? '[]') as string[],
  ids => SecureStore.setItemAsync(seenKey, JSON.stringify(ids)),
);

Notifications.setNotificationHandler({
  handleNotification: async notification => {
    const preference = subscription.value ?? JSON.parse(await SecureStore.getItemAsync(storageKey) ?? 'null');
    const show = await dedup.accept(notification.request.content.data?.notification_id, preference?.enabled === true);
    return { shouldShowBanner: show, shouldShowList: show, shouldPlaySound: show, shouldSetBadge: false };
  },
});
