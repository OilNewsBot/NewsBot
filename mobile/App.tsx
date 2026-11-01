import { useEffect, useState } from 'react';
import { Alert, AppState, Linking, StyleSheet, Switch, Text, View } from 'react-native';
import * as Notifications from 'expo-notifications';
import { subscribe, subscription } from './src/native';

export default function App() {
  const [value, setValue] = useState(subscription.value);
  const [busy, setBusy] = useState(true);

  useEffect(() => {
    let mounted = true;
    let refreshing = false;
    const unsubscribe = subscribe(() => { if (mounted) setValue(subscription.value); });
    const refresh = async () => {
      if (refreshing) return;
      refreshing = true;
      try { await subscription.refresh(); }
      catch { /* Durable pending state is shown by the label; retry while active. */ }
      finally { refreshing = false; if (mounted) setBusy(false); }
    };
    void refresh();
    const state = AppState.addEventListener('change', next => { if (next === 'active') void refresh(); });
    const tokens = Notifications.addPushTokenListener(() => { void refresh(); });
    const retry = setInterval(() => {
      if (AppState.currentState === 'active') void refresh();
    }, 30000);
    return () => { mounted = false; unsubscribe(); state.remove(); tokens.remove(); clearInterval(retry); };
  }, []);

  const toggle = async (enabled: boolean) => {
    setBusy(true);
    try { await subscription.setEnabled(enabled); }
    catch (error) {
      const pending = subscription.value?.pending;
      Alert.alert('Notifications', [
        error instanceof Error ? error.message : 'Could not update notifications.',
        pending ? 'Your choice is saved and will retry while this app is open. Until it syncs, the server may still send notifications. You can also disable them in phone Settings.' : '',
      ].filter(Boolean).join('\n\n'), [
        { text: 'OK' }, { text: 'Phone Settings', onPress: () => { void Linking.openSettings(); } },
      ]);
    } finally { setBusy(false); }
  };

  return (
    <View style={styles.screen}>
      <View style={styles.row}>
        <Text style={styles.label}>{value?.pending ? 'Notifications · sync pending' : 'Notifications'}</Text>
        <Switch
          accessibilityLabel="Enable NewsBot notifications"
          accessibilityHint={value?.pending ? 'Waiting to sync with NewsBot' : undefined}
          disabled={busy}
          value={value?.enabled ?? false}
          onValueChange={enabled => { void toggle(enabled); }}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { flex: 1, backgroundColor: '#fff', justifyContent: 'center', padding: 24 },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 16 },
  label: { flexShrink: 1, color: '#171717', fontSize: 18 },
});
