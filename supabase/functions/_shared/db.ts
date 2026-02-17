import {
	Kysely,
	PostgresAdapter,
	PostgresIntrospector,
	PostgresQueryCompiler,
	sql,
} from "kysely";
import { Pool } from "postgres";
import type { KyselyDatabase } from "../../../src/lib/types.ts";
import { PostgresDriver } from "./kyselyDriver.ts";

const postgresConnectionString = Deno.env.get("POSTGRES_CONNECTION_STRING");

const pool = postgresConnectionString
	? new Pool(postgresConnectionString, 1)
	: new Pool(
			{
				hostname: Deno.env.get("POSTGRES_HOST") ?? "db",
				port: Number(Deno.env.get("POSTGRES_PORT") ?? "5432"),
				user: Deno.env.get("POSTGRES_USER") ?? "postgres",
				password: Deno.env.get("POSTGRES_PASSWORD") ?? "postgres",
				database: Deno.env.get("POSTGRES_DB") ?? "postgres",
			},
			1,
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
		},
	},
});

export { db, sql };
