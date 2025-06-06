import Stripe from "stripe";
import { Kysely, type QueryExecutorProvider, sql } from "kysely";
import dayjs from "dayjs";
import type { KyselyDatabase } from "../src/lib/types";
import { PostgresJSDialect } from 'kysely-postgres-js';
import postgres from 'postgres';


if (!process.env.CUSTOMER_ID) {
    throw new Error("Missing CUSTOMER_ID in environment variables");
}

if (!process.env.STRIPE_SECRET_KEY) {
    throw new Error("Missing STRIPE_SECRET_KEY in environment variables");
}
if (!process.env.DATABASE_URL) {
    throw new Error("Missing DATABASE_URL in environment variables");
}

const monthlyPriceId = process.env.MONTHLY_PRICE_ID!;
const annualPriceId = process.env.ANNUAL_PRICE_ID!;
const customerId = process.env.CUSTOMER_ID!;


if (!monthlyPriceId || !annualPriceId || !customerId) {
    throw new Error("Missing price IDs or customer ID in environment variables");
}

function getKyselyClient(connectionString: string) {
	return new Kysely<KyselyDatabase>({
		dialect: new PostgresJSDialect({
			postgres: postgres(
				connectionString,
				{
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
				}
			)
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
    executor: QueryExecutorProvider,
): Promise<string> {
    // Store the new session
    const result = await sql<{ id: string }>`
    UPDATE payment_sessions
    SET
      monthly_subscription_id = ${monthlySubscription.id}::text,
      annual_subscription_id = ${annualSubscription.id}::text,
      monthly_payment_intent_id = ${monthlyPaymentIntentId}::text,
      annual_payment_intent_id = ${annualPaymentIntentId}::text,
      monthly_amount = ${monthlyAmount}::integer,
      annual_amount = ${annualAmount}::integer,
      total_amount = ${totalAmount}::integer,
      expires_at = ${dayjs().add(24, 'hour').toISOString()}::timestamptz,
      discounted_monthly_amount = NULL,
      discounted_annual_amount = NULL,
      discount_percentage = NULL
    WHERE user_id = ${userId}::uuid
    RETURNING id
  `.execute(executor);

    return result.rows[0]?.id;
}

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: "2025-04-30.basil",
    maxNetworkRetries: 3,
    timeout: 30 * 1000,
    httpClient: Stripe.createFetchHttpClient(),
});

async function resetExpiredSubscriptions() {
    const expiredSubscriptions = await stripe.subscriptions.list({
        status: "incomplete_expired",
        expand: ["data.latest_invoice.payments"],
    });

    console.log(
        `Found ${expiredSubscriptions.data.length} expired subscriptions`,
    );
    await kysely.transaction().execute(async (trx) => {
        console.log(customerId);
        const userId = await trx.selectFrom("user_profiles").select(
            "supabase_user_id",
        ).where("customer_id", "=", customerId)
            .executeTakeFirst().then((r) => r?.supabase_user_id);
        if (!userId) {
            console.error(
                `User not found for customer ${customerId}`,
            );
            return;
        }
        const [monthlySubscription, annualSubscription] = await Promise.all(
            [
                stripe.subscriptions.create({
                    customer: customerId,
                    items: [{ price: monthlyPriceId }],
                    billing_cycle_anchor_config: {
                        day_of_month: 1,
                    },
                    payment_behavior: "default_incomplete",
                    payment_settings: {
                        payment_method_types: ["sepa_debit"],
                    },
                    expand: ["latest_invoice.payments"],
                    collection_method: "charge_automatically",
                }),
                stripe.subscriptions.create({
                    customer: customerId,
                    items: [{ price: annualPriceId }],
                    payment_behavior: "default_incomplete",
                    payment_settings: {
                        payment_method_types: ["sepa_debit"],
                    },
                    billing_cycle_anchor_config: {
                        month: 1,
                        day_of_month: 7,
                    },
                    expand: ["latest_invoice.payments"],
                    collection_method: "charge_automatically",
                }),
            ],
        );
        console.log(
            `Created subscriptions for user ${customerId}`,
        );
        const monthlyInvoice = monthlySubscription
            .latest_invoice as Stripe.Invoice;
        const annualInvoice = annualSubscription
            .latest_invoice as Stripe.Invoice;
        const monthlyPayment = monthlyInvoice.payments?.data?.[0]?.payment!;
        const annualPayment = annualInvoice.payments?.data?.[0]?.payment!;
        console.log(
            `Created payment intents for user ${customerId}`,
        );
        console.debug(monthlyPayment, annualPayment);

        // Store the payment session using Kysely
        console.log(
            `Creating payment session for user ${customerId}`,
        );
        console.log(
            monthlySubscription,
            annualSubscription,
            monthlyPayment,
            annualPayment,
            monthlyInvoice,
            annualInvoice,
        );
        await createPaymentSession(
            userId,
            monthlySubscription,
            annualSubscription,
            monthlyPayment.payment_intent! as string,
            annualPayment.payment_intent! as string,
            // Price of the plan itself without proration
            monthlySubscription.items.data[0].plan.amount! as number,
            annualSubscription.items.data[0].plan.amount! as number,
            // Total amount due for both subscriptions right now
            monthlyInvoice.amount_due! + annualInvoice.amount_due!,
            trx,
        );
        console.log(`Created payment session for user ${userId}`);
    });
}
resetExpiredSubscriptions().then(() => process.exit(0))
    .catch((err) => {
        console.error(err);
        process.exit(-1);
    });
