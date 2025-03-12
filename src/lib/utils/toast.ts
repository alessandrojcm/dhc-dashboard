import { getContext } from 'svelte';

export type ToastType = 'success' | 'error' | 'info' | 'warning';

export interface ToastStore {
  success: (message: string) => string;
  error: (message: string) => string;
  info: (message: string) => string;
  warning: (message: string) => string;
}

/**
 * Get the toast store from context
 * @returns The toast store with methods for showing different types of toasts
 */
export function useToast(): ToastStore {
  return getContext<ToastStore>('toast');
}
