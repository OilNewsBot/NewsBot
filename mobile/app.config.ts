import type { ExpoConfig } from 'expo/config';

const config: ExpoConfig = {
  name: 'NewsBot',
  slug: 'newsbot-mobile',
  version: '0.1.0',
  orientation: 'portrait',
  platforms: ['ios', 'android'],
  ios: {
    bundleIdentifier: process.env.NEWSBOT_IOS_BUNDLE_ID || 'com.example.newsbot',
    supportsTablet: false,
    config: { usesNonExemptEncryption: false },
  },
  android: {
    package: process.env.NEWSBOT_ANDROID_PACKAGE || 'com.example.newsbot',
    googleServicesFile: process.env.GOOGLE_SERVICES_JSON,
  },
  plugins: [
    ['expo-notifications', { defaultChannel: 'newsbot' }],
    'expo-secure-store',
  ],
  extra: { eas: { projectId: process.env.EXPO_PUBLIC_EAS_PROJECT_ID } },
};

export default config;
