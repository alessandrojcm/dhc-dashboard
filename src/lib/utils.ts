import { type ClassValue, clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';
import type { HTMLAttributes } from 'svelte/elements';

export function cn(...inputs: ClassValue[]) {
	return twMerge(clsx(inputs));
}

// Utility types for component props
export type WithElementRef<T extends HTMLAttributes<HTMLElement>> = T & {
	ref?: HTMLElement | null;
};

export type WithoutChildren<T extends HTMLAttributes<HTMLElement>> = Omit<T, 'children'>;

export type WithoutChild<T> = Omit<T, 'child'>;

export type WithoutChildrenOrChild<T> = Omit<T, 'children' | 'child'>;
