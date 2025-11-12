import Stripe from 'stripe';
import { Kysely, type QueryExecutorProvider, sql } from 'kysely';
import dayjs from 'dayjs';
import type { KyselyDatabase } from '../src/lib/types';
import { PostgresJSDialect } from 'kysely-postgres-js';
import postgres from 'postgres';

if (!process.env.STRIPE_SECRET_KEY) {
	throw new Error('Missing STRIPE_SECRET_KEY in environment variables');
}
if (!process.env.DATABASE_URL) {
	throw new Error('Missing DATABASE_URL in environment variables');
}

const monthlyPriceId = process.env.MONTHLY_PRICE_ID!;
const annualPriceId = process.env.ANNUAL_PRICE_ID!;

if (!monthlyPriceId || !annualPriceId) {
	throw new Error('Missing price IDs in environment variables');
}

function getKyselyClient(connectionString: string) {
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

const kysely = getKyselyClient(process.env.DATABASE_URL);

export async function createPaymentSession(
	userId: string,
	monthlySubscription: Stripe.Subscription,
	annualSubscription: Stripe.Subscription,
	monthlyPaymentIntentId: string,
	annualPaymentIntentId: string,
	monthlyAmount: number,
	annualAmount: number,
	totalAmount: number,
	executor: QueryExecutorProvider
): Promise<string> {
	// Store the new session
	const result = await sql<{ id: string }>`
        INSERT INTO payment_sessions (
          user_id,
          monthly_subscription_id,
          annual_subscription_id,
          monthly_payment_intent_id,
          annual_payment_intent_id,
          monthly_amount,
          annual_amount,
          total_amount,
          expires_at
        ) VALUES (
          ${userId}::uuid,
          ${monthlySubscription.id}::text,
          ${annualSubscription.id}::text,
          ${monthlyPaymentIntentId}::text,
          ${annualPaymentIntentId}::text,
          ${monthlyAmount}::integer,
          ${annualAmount}::integer,
          ${totalAmount}::integer,
          ${dayjs().add(24, 'hour').toISOString()}::timestamptz
        )
        RETURNING id
      `.execute(executor);

	return result.rows[0]?.id;
}

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
	apiVersion: '2025-04-30.basil',
	maxNetworkRetries: 3,
	timeout: 30 * 1000,
	httpClient: Stripe.createFetchHttpClient()
});

async function resetExpiredSubscriptions() {
	await kysely.transaction().execute(async (trx) => {
		const invitesWithoutPayment = await trx
			.selectFrom('invitations')
			.select('invitations.user_id')
			.where('invitations.status', '=', 'pending')
			.leftJoin('payment_sessions', 'invitations.user_id', 'payment_sessions.user_id')
			.where('payment_sessions.id', 'is', null)
			.execute();
		console.log(`Found ${invitesWithoutPayment.length} invites without payment`);

		for (const invite of invitesWithoutPayment) {
			const customer = await trx
				.selectFrom('user_profiles')
				.select('customer_id')
				.where('supabase_user_id', '=', invite.user_id)
				.executeTakeFirst()
				.then((c) => c?.customer_id);
			if (!customer) {
				console.error(`User ${invite.user_id} not found`);
				continue;
			}
			const [monthlySubscription, annualSubscription] = await Promise.all([
				stripe.subscriptions.create({
					customer: customer as string,
					items: [{ price: monthlyPriceId }],
					billing_cycle_anchor_config: {
						day_of_month: 1
					},
					payment_behavior: 'default_incomplete',
					payment_settings: {
						payment_method_types: ['sepa_debit']
					},
					expand: ['latest_invoice.payments'],
					collection_method: 'charge_automatically'
				}),
				stripe.subscriptions.create({
					customer: customer,
					items: [{ price: annualPriceId }],
					payment_behavior: 'default_incomplete',
					payment_settings: {
						payment_method_types: ['sepa_debit']
					},
					billing_cycle_anchor_config: {
						month: 1,
						day_of_month: 7
					},
					expand: ['latest_invoice.payments'],
					collection_method: 'charge_automatically'
				})
			]);
			console.log(`Created subscriptions for user ${customer}`);
			const monthlyInvoice = monthlySubscription.latest_invoice as Stripe.Invoice;
			const annualInvoice = annualSubscription.latest_invoice as Stripe.Invoice;
			const monthlyPayment = monthlyInvoice.payments?.data?.[0]?.payment!;
			const annualPayment = annualInvoice.payments?.data?.[0]?.payment!;
			console.log(`Created payment intents for user ${customer}`);
			console.debug(monthlyPayment, annualPayment);

			// Store the payment session using Kysely
			console.log(`Creating payment session for user ${customer}`);
			console.log(
				monthlySubscription,
				annualSubscription,
				monthlyPayment,
				annualPayment,
				monthlyInvoice,
				annualInvoice
			);
			await createPaymentSession(
				invite.user_id,
				monthlySubscription,
				annualSubscription,
				monthlyPayment.payment_intent! as string,
				annualPayment.payment_intent! as string,
				// Price of the plan itself without proration
				monthlySubscription.items.data[0].plan.amount! as number,
				annualSubscription.items.data[0].plan.amount! as number,
				// Total amount due for both subscriptions right now
				monthlyInvoice.amount_due! + annualInvoice.amount_due!,
				trx
			);
			console.log(`Created payment session for user ${invite.user_id}`);
		}
	});
}
resetExpiredSubscriptions()
	.then(() => process.exit(0))
	.catch((err) => {
		console.error(err);
		process.exit(-1);
	});
