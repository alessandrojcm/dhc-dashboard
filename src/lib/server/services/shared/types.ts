import type { Session } from '@supabase/supabase-js';
import type { Kysely, Transaction } from 'kysely';
import type { KyselyDatabase } from '$lib/types';
import type { Logger } from './logger';

/**
 * Base configuration for all services
 */
export interface ServiceConfig {
	/**
	 * Kysely database instance
	 */
	kysely: Kysely<KyselyDatabase>;

	/**
	 * Supabase session for RLS
	 */
	session: Session;

	/**
	 * Optional logger (defaults to console if not provided)
	 */
	logger?: Logger;
}

/**
 * Re-export commonly used types for convenience
 */
export type { Kysely, Transaction, KyselyDatabase, Session, Logger };
