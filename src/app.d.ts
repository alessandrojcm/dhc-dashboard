/// <reference types="@sveltejs/kit" />
import type { Session, SupabaseClient, User } from '@supabase/supabase-js';
import type { Database } from './database.types';
import { Env } from '../worker-configuration';
// See https://svelte.dev/docs/kit/types#app.d.ts
// for information about these interfaces
declare global {
	declare namespace App {
		// interface Error {}

		interface Platform {
			env?: Env;
		}
		interface Locals {
			supabase: SupabaseClient<Database>;
			safeGetSession: () => Promise<{ session: Session | null; user: User | null }>;
			session: Session | null;
			user: User | null;
		}
		interface PageData {
			session: Session | null;
		}
		// interface PageState {}
		// interface Platform {}
	}
}

declare module '$env/static/public' {
	export const PUBLIC_SUPABASE_URL: string;
	export const PUBLIC_SUPABASE_ANON_KEY: string;
	export const PUBLIC_SITE_URL: string;
}
