import { type QueryExecutorProvider, sql } from "kysely";

/**
 * Updates a user profile with a customer ID
 */
export async function updateUserProfileWithCustomerId(
	userId: string,
	customerId: string,
	executor: QueryExecutorProvider,
): Promise<void> {
	await sql`
    UPDATE user_profiles
    SET customer_id = ${customerId}::text
    WHERE supabase_user_id = ${userId}::uuid
  `.execute(executor);
}
