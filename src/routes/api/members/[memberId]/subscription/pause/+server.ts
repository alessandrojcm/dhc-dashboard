import * as Sentry from '@sentry/sveltekit';
import { json } from '@sveltejs/kit';
import dayjs from 'dayjs';
import * as v from 'valibot';
import { authorize } from '$lib/server/auth';
import { MEMBERSHIP_FEE_LOOKUP_NAME } from '$lib/server/constants';
import { getKyselyClient } from '$lib/server/kysely';
import { SETTINGS_ROLES } from '$lib/server/roles';
import { stripeClient } from '$lib/server/stripe';
import type { RequestHandler } from './$types';

const pauseRequestSchema = v.object({
	pauseUntil: v.pipe(
		v.string(),
		v.transform((str) => new Date(str)),
		v.check((date) => {
			const pauseDate = dayjs(date);
			const now = dayjs();
			const minDate = now.add(1, 'day');
			const maxDate = now.add(6, 'months');

			return pauseDate.isAfter(minDate) && pauseDate.isBefore(maxDate);
		}, 'Pause date must be between 1 day and 6 months from now')
	)
});

export const POST: RequestHandler = async ({ request, params, locals, platform }) => {
	try {
		const session = (await locals.safeGetSession())?.session;
		const { memberId } = params;
		if (session?.user?.id !== memberId) {
			await authorize(locals, SETTINGS_ROLES);
		}

		const body = await request.json();
		const validatedData = v.safeParse(pauseRequestSchema, body);

		if (!validatedData.success) {
			const errorMessage = validatedData.issues[0]?.message || 'Invalid request data';
			return json({ success: false, error: errorMessage }, { status: 400 });
		}

		const { pauseUntil } = validatedData.output;
		const pauseDate = dayjs(pauseUntil);

		if (!platform?.env?.HYPERDRIVE) {
			return json({ success: false, error: 'Platform configuration missing' }, { status: 500 });
		}

		const kysely = getKyselyClient(platform.env.HYPERDRIVE);

		// Get customer ID from database
		const member = await kysely
			.selectFrom('member_management_view')
			.select(['customer_id', 'subscription_paused_until'])
			.where('id', '=', memberId)
			.executeTakeFirst();

		if (!member?.customer_id) {
			return json({ success: false, error: 'Member or customer not found' }, { status: 404 });
		}

		// Find membership subscription in Stripe
		const subscriptions = await stripeClient.subscriptions.list({
			customer: member.customer_id,
			status: 'active',
			limit: 10
		});

		const membershipSub = subscriptions.data.find((sub) =>
			sub.items.data.some((item) => item.price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME)
		);

		if (!membershipSub) {
			return json(
				{ success: false, error: 'Active membership subscription not found' },
				{ status: 404 }
			);
		}
		// Pause subscription in Stripe
		const updatedSub = await stripeClient.subscriptions.update(membershipSub.id, {
			pause_collection: {
				behavior: 'void',
				resumes_at: pauseDate.unix()
			},
			expand: ['pause_collection']
		});

		if (updatedSub.pause_collection === null) {
			return json({ success: false, error: 'Error pausing subscription' }, { status: 500 });
		}

		// Update database
		await kysely
			.updateTable('member_profiles')
			.set({ subscription_paused_until: pauseDate.toISOString() })
			.where('id', '=', memberId)
			.execute();

		return json({ success: true, subscription: updatedSub });
	} catch (err) {
		Sentry.captureException(err);
		console.error('Subscription pause error:', err);

		if (err instanceof Error && err.message === 'Unauthorized') {
			return json({ success: false, error: 'Unauthorized' }, { status: 403 });
		}

		return json({ success: false, error: 'Failed to pause subscription' }, { status: 500 });
	}
};

export const DELETE: RequestHandler = async ({ params, locals, platform }) => {
	try {
		const session = (await locals.safeGetSession())?.session;
		const { memberId } = params;
		if (session?.user?.id !== memberId) {
			await authorize(locals, SETTINGS_ROLES);
		}

		if (!platform?.env?.HYPERDRIVE) {
			return json({ success: false, error: 'Platform configuration missing' }, { status: 500 });
		}

		const kysely = getKyselyClient(platform.env.HYPERDRIVE);

		// Get customer ID and current pause status
		const member = await kysely
			.selectFrom('member_management_view')
			.select(['customer_id', 'subscription_paused_until'])
			.where('id', '=', memberId)
			.executeTakeFirst();

		if (!member?.customer_id) {
			return json({ success: false, error: 'Member or customer not found' }, { status: 404 });
		}

		if (!member.subscription_paused_until) {
			return json({ success: false, error: 'Subscription is not paused' }, { status: 400 });
		}

		// Find paused subscription in Stripe
		const subscriptions = await stripeClient.subscriptions.list({
			customer: member.customer_id,
			limit: 10
		});

		const membershipSub = subscriptions.data.find(
			(sub) =>
				sub.items.data.some((item) => item.price.lookup_key === MEMBERSHIP_FEE_LOOKUP_NAME) &&
				sub.pause_collection !== null
		);

		if (!membershipSub) {
			return json(
				{ success: false, error: 'Paused membership subscription not found' },
				{ status: 404 }
			);
		}

		// Resume subscription in Stripe
		const updatedSub = await stripeClient.subscriptions.update(membershipSub.id, {
			pause_collection: null
		});

		// Clear database pause field
		await kysely
			.updateTable('member_profiles')
			.set({ subscription_paused_until: null })
			.where('id', '=', memberId)
			.execute();

		return json({ success: true, subscription: updatedSub });
	} catch (err) {
		Sentry.captureException(err);
		console.error('Subscription resume error:', err);

		if (err instanceof Error && err.message === 'Unauthorized') {
			return json({ success: false, error: 'Unauthorized' }, { status: 403 });
		}

		return json({ success: false, error: 'Failed to resume subscription' }, { status: 500 });
	}
};
