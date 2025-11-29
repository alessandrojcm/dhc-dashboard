import {
	error,
	fail,
	isActionFailure,
	isRedirect,
	redirect,
} from "@sveltejs/kit";
import { superValidate } from "sveltekit-superforms";
import { valibot } from "sveltekit-superforms/adapters";
import { setMessage } from "sveltekit-superforms/client";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createContainerService,
	ContainerUpdateSchema,
} from "$lib/server/services/inventory";

export const load = async ({
	params,
	locals,
	platform,
}: {
	params: any;
	locals: App.Locals;
	platform: App.Platform;
}) => {
	const session = await authorize(locals, INVENTORY_ROLES);
	const containerService = createContainerService(platform!, session);

	// Get container by ID
	const container = await containerService.findById(params.id);

	if (!container) {
		throw error(404, "Container not found");
	}

	// Get available parent containers (excluding self and descendants)
	const availableContainers = await containerService.getAvailableParents(
		params.id,
	);

	return {
		form: await superValidate(
			{
				name: container.name,
				description: container.description || "",
				parent_container_id: container.parent_container_id || "",
			},
			valibot(ContainerUpdateSchema),
		),
		containers: availableContainers,
		container,
	};
};

export const actions = {
	update: async ({ params, request, locals, platform }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(ContainerUpdateSchema));

		if (!form.valid) {
			return fail(400, { form });
		}

		try {
			const containerService = createContainerService(platform!, session);
			await containerService.update(params.id, form.data);

			redirect(303, `/dashboard/inventory/containers/${params.id}`);
		} catch (error) {
			if (isRedirect(error)) throw error;
			console.error("Error updating container:", error);
			return fail(500, {
				form,
				error: "Failed to update container. Please try again.",
			});
		}
	},

	delete: async ({ params, locals, platform, request }) => {
		const session = await authorize(locals, INVENTORY_ROLES);
		const form = await superValidate(request, valibot(ContainerUpdateSchema));

		try {
			const containerService = createContainerService(platform!, session);
			const containerWithCount = await containerService.getWithItemCount(
				params.id,
			);

			if (containerWithCount.itemCount > 0) {
				return setMessage(
					form,
					"Cannot delete a container that contains items.",
					{
						status: 400,
					},
				);
			}

			await containerService.delete(params.id);
			return redirect(303, "/dashboard/inventory/containers");
		} catch (error) {
			if (isRedirect(error) || isActionFailure(error)) throw error;
			console.error("Error deleting container:", error);
			return fail(500, {
				error: "Failed to delete container. Please try again.",
			});
		}
	},
};
