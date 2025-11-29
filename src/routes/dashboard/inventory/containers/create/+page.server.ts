import * as Sentry from "@sentry/sveltekit";
import { fail, isRedirect, redirect } from "@sveltejs/kit";
import { superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createContainerService,
	ContainerCreateSchema,
} from "$lib/server/services/inventory";

export const load = async ({
	locals,
	platform,
}: {
	locals: App.Locals;
	platform: App.Platform;
}) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const containerService = createContainerService(platform!, session);

	// Load existing containers for parent selection
	const containers = await containerService.findMany();

	return {
		form: await superValidate(valibot(ContainerCreateSchema)),
		containers: containers || [],
	};
};

export const actions = {
	default: async ({ request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(ContainerCreateSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const containerService = createContainerService(platform!, session);
			const container = await containerService.create(form.data);

			redirect(303, `/dashboard/inventory/containers/${container.id}`);
		} catch (error) {
			if (isRedirect(error)) {
				throw error;
			}
			Sentry.captureException(error);
			console.error("Error creating container:", error);
			return fail(500, {
				form,
				error: "Failed to create container. Please try again.",
			});
		}
	},
};
