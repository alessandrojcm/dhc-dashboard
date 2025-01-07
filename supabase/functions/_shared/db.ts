import { Pool } from 'https://deno.land/x/postgres@v0.17.0/mod.ts';
import {
	Kysely,
	PostgresAdapter,
	PostgresIntrospector,
	PostgresQueryCompiler
} from 'https://esm.sh/kysely@0.23.4';
import { PostgresDriver } from './kyselyDriver.ts';
import type { KyselyDatabase } from '../../../src/lib/types.ts';

const pool = new Pool(
	{
		database: Deno.env.get('POSTGRES_DB'),
		hostname: Deno.env.get('POSTGRES_HOST'),
		user: Deno.env.get('POSTGRES_USER'),
		port: 5432,
		password: Deno.env.get('POSTGRES_PASSWORD')
	},
	1
);

const db = new Kysely<KyselyDatabase>({
	dialect: {
		createAdapter() {
			return new PostgresAdapter();
		},
		createDriver() {
			return new PostgresDriver({ pool });
		},
		createIntrospector(db: Kysely<unknown>) {
			return new PostgresIntrospector(db);
		},
		createQueryCompiler() {
			return new PostgresQueryCompiler();
		}
	}
});

export { db };
