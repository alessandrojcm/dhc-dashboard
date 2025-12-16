import type { Session } from '@supabase/supabase-js';
import { jwtDecode } from 'jwt-decode';
import { Kysely, sql, type Transaction } from 'kysely';
import { PostgresJSDialect } from 'kysely-postgres-js';
import postgres from 'postgres';
import type { KyselyDatabase } from '$lib/types';

interface RLSData {
	/**
	 * Claims to be set in the transaction
	 */
	claims: Session;
}

type SupabaseToken = {
	iss?: string;
	sub?: string;
	aud?: string[] | string;
	exp?: number;
	nbf?: number;
	iat?: number;
	jti?: string;
	role?: string;
};

export function getKyselyClient(connectionString: string) {
	return new Kysely<KyselyDatabase>({
		dialect: new PostgresJSDialect({
			postgres: postgres(connectionString, {
				prepare: true,
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
			})
		})
	});
}

export async function executeWithRLS<T>(
	kysely: Kysely<KyselyDatabase>,
	authData: RLSData,
	callback: (trx: Transaction<KyselyDatabase>) => Promise<T>
) {
	const decoded = jwtDecode(authData.claims.access_token) as SupabaseToken;
	return await kysely.transaction().execute(async (trx) => {
		// set transaction level auth variables and run transaction
		await sql`
			-- auth.jwt()
			select set_config('request.jwt.claims', ${sql.lit(
				JSON.stringify(authData.claims.access_token)
			)}, TRUE);
			-- auth.uid()
			select set_config('request.jwt.claim.sub', ${sql.lit(decoded.sub ?? '')}, TRUE);
			-- set local role
			set local role ${sql.raw(decoded.role ?? 'anon')};
		`.execute(trx);
		return await callback(trx);
	});
}

export { sql };
