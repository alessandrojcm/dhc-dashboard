import type { KyselyDatabase } from '$lib/types';
import { Kysely, sql } from 'kysely';
import { env } from '$env/dynamic/private';
import postgres from 'postgres';
import { PostgresJSDialect } from 'kysely-postgres-js';

export const kysely = new Kysely<KyselyDatabase>({
	dialect: new PostgresJSDialect({
		postgres: postgres(
			`postgresql://${env.POSTGRES_USER}:${env.POSTGRES_PASSWORD}@${env.POSTGRES_HOST}:${env.POSTGRES_PORT}/${env.POSTGRES_DB}`,
			{
				transform: {
					value: {
						from: (value) => {
							if (value instanceof Date) {
								return value.toISOString();
							} else {
								return value;
							}
						}
					}
				}
			}
		)
	})
});

export { sql };
