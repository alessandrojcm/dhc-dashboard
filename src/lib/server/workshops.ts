import { executeWithRLS, getKyselyClient } from './kysely';
import type { Database } from '$database';
import type { Session } from '@supabase/supabase-js';
import { stripeClient } from '$lib/server/stripe';

export type ClubActivity = Database['public']['Tables']['club_activities']['Row'];
export type ClubActivityInsert = Database['public']['Tables']['club_activities']['Insert'];
export type ClubActivityUpdate = Database['public']['Tables']['club_activities']['Update'];

export async function createWorkshop(
	data: ClubActivityInsert,
	session: Session,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: session }, async (trx) => {
		// For single-day workshops, set end_date to start_date
		const workshopData = {
			...data,
			created_by: session.user.id
		};

		return await trx
			.insertInto('club_activities')
			.values(workshopData)
			.returning([
				'id',
				'title',
				'description',
				'location',
				'start_date',
				'end_date',
				'max_capacity',
				'price_member',
				'price_non_member',
				'is_public',
				'refund_days',
				'status',
				'created_at',
				'updated_at',
				'created_by'
			])
			.executeTakeFirstOrThrow();
	});
	return result;
}

export async function updateWorkshop(
	id: string,
	data: ClubActivityUpdate,
	session: Session,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: session }, async (trx) => {
		// For single-day workshops, set end_date to start_date if start_date is being updated
		const updateData = data.start_date ? { ...data, end_date: data.start_date } : data;

		return await trx
			.updateTable('club_activities')
			.set(updateData)
			.where('id', '=', id)
			.returning([
				'id',
				'title',
				'description',
				'location',
				'start_date',
				'end_date',
				'max_capacity',
				'price_member',
				'price_non_member',
				'is_public',
				'refund_days',
				'status',
				'created_at',
				'updated_at',
				'created_by'
			])
			.executeTakeFirstOrThrow();
	});
	return result;
}

export async function deleteWorkshop(
	id: string,
	session: Session,
	platform: App.Platform
): Promise<void> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	await executeWithRLS(kysely, { claims: session }, async (trx) => {
		await trx
			.deleteFrom('club_activities')
			.where('id', '=', id)
			.where('status', '=', 'planned')
			.execute();
	});
}

export async function publishWorkshop(
	id: string,
	session: Session,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: session }, async (trx) => {
		return await trx
			.updateTable('club_activities')
			.set({ status: 'published' })
			.where('id', '=', id)
			.where('status', '=', 'planned')
			.returning([
				'id',
				'title',
				'description',
				'location',
				'start_date',
				'end_date',
				'max_capacity',
				'price_member',
				'price_non_member',
				'is_public',
				'refund_days',
				'status',
				'created_at',
				'updated_at',
				'created_by'
			])
			.executeTakeFirstOrThrow();
	});
	return result;
}

export async function cancelWorkshop(
	id: string,
	session: Session,
	platform: App.Platform
): Promise<ClubActivity> {
	const kysely = getKyselyClient(platform.env.HYPERDRIVE);
	const result = await executeWithRLS(kysely, { claims: session }, async (trx) => {
		const registrations = await trx
			.selectFrom('club_activity_registrations')
			.select(['stripe_checkout_session_id', 'amount_paid'])
			.where('club_activity_id', '=', id)
			.where('stripe_checkout_session_id', 'is not', 'null')
			.execute();

		await Promise.all(
			registrations.map(async (registration) => {
				const paymentIntent = await stripeClient.paymentIntents.retrieve(
					registration.stripe_checkout_session_id!
				);
				if (!paymentIntent) {
					return Promise.resolve();
				}
				return stripeClient.refunds.create({
					payment_intent: paymentIntent.id,
					amount: registration.amount_paid,
					reason: 'requested_by_customer'
				});
			})
		);

		return await trx
			.updateTable('club_activities')
			.set({ status: 'cancelled' })
			.where('id', '=', id)
			.where('status', '=', 'published')
			.returning([
				'id',
				'title',
				'description',
				'location',
				'start_date',
				'end_date',
				'max_capacity',
				'price_member',
				'price_non_member',
				'is_public',
				'refund_days',
				'status',
				'created_at',
				'updated_at',
				'created_by'
			])
			.executeTakeFirstOrThrow();
	});
	return result;
}
