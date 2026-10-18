import { useSyncExternalStore } from 'react';
import { isSessionEnded, subscribeSessionEnded } from '../lib/sessionEnd.js';

export function useSessionEnded() {
  return useSyncExternalStore(subscribeSessionEnded, isSessionEnded, () => false);
}
