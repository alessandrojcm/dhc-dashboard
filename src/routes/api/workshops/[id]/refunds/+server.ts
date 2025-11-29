import * as Sentry from "@sentry/sveltekit";
import type { RequestHandler } from "@sveltejs/kit";
import { json } from "@sveltejs/kit";
import { safeParse } from "valibot";
import { ProcessRefundSchema } from "$lib/schemas/refunds";
import { authorize } from "$lib/server/auth";
import { createRefundService } from "$lib/server/services/workshops";
import { WORKSHOP_ROLES } from "$lib/server/roles";

export const GET: RequestHandler = async ({ locals, params, platform }) => {
	try {
		const session = await authorize(locals, WORKSHOP_ROLES);
		const refundService = createRefundService(platform!, session);
		const refunds = await refundService.getWorkshopRefunds(params.id!);
		return json({ success: true, refunds });
	} catch (error) {
		Sentry.captureException(error);
		return json(
			{ success: false, error: (error as Error).message },
			{ status: 500 },
		);
	}
};

export const POST: RequestHandler = async ({ request, locals, platform }) => {
	try {
		const { session } = await locals.safeGetSession();

		if (!session) {
			return json(
				{ success: false, error: "Authentication required" },
				{ status: 401 },
			);
		}

		const body = await request.json();
		const result = safeParse(ProcessRefundSchema, body);

		if (!result.success) {
			return json(
				{ success: false, error: "Invalid data", issues: result.issues },
				{ status: 400 },
			);
		}

		const { getKyselyClient, executeWithRLS } = await import(
			"$lib/server/kysely"
		);
		const kysely = getKyselyClient(platform?.env.HYPERDRIVE);

		const registration = await executeWithRLS(
			kysely,
			{ claims: session },
			async (trx) => {
				return await trx
					.selectFrom("club_activity_registrations")
					.select(["member_user_id"])
					.where("id", "=", result.output.registration_id)
					.executeTakeFirst();
			},
		);

		if (!registration) {
			return json(
				{ success: false, error: "Registration not found" },
				{ status: 404 },
			);
		}

		const isOwner = registration.member_user_id === session.user.id;

		// 3) If not the owner, check if they are admin/coordinator
		if (!isOwner) {
			try {
				await authorize(locals, WORKSHOP_ROLES);
			} catch {
				return json(
					{
						success: false,
						error: "You can only request refunds for your own registrations",
					},
					{ status: 403 },
				);
			}
		}

		const refundService = createRefundService(platform!, session);
		const refund = await refundService.processRefund(
			result.output.registration_id,
			result.output.reason,
		);

		return json({ success: true, refund });
	} catch (error) {
		console.error("Refund processing error:", error);
		Sentry.captureException(error);
		const errorMessage =
			error instanceof Error ? error.message : "Unknown error occurred";
		return json({ success: false, error: errorMessage }, { status: 500 });
	}
};
