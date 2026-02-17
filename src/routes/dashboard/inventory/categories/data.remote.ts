import { form, getRequestEvent } from "$app/server";
import { redirect } from "@sveltejs/kit";
import * as v from "valibot";
import { authorize } from "$lib/server/auth";
import { INVENTORY_ROLES } from "$lib/server/roles";
import {
	createCategoryService,
	CategoryCreateSchema,
	CategoryUpdateSchema,
} from "$lib/server/services/inventory";

export const createCategory = form(CategoryCreateSchema, async (data) => {
	const event = getRequestEvent();
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const categoryService = createCategoryService(event.platform!, session);

	await categoryService.create(data);

	redirect(303, "/dashboard/inventory/categories");
});

export const updateCategory = form(CategoryUpdateSchema, async (data) => {
	const event = getRequestEvent();
	const categoryId = event.params.id;
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const categoryService = createCategoryService(event.platform!, session);

	await categoryService.update(categoryId!, data);

	redirect(303, "/dashboard/inventory/categories");
});

export const deleteCategory = form(v.object({}), async () => {
	const event = getRequestEvent();
	const categoryId = event.params.id;
	const session = await authorize(event.locals, INVENTORY_ROLES);
	const categoryService = createCategoryService(event.platform!, session);

	await categoryService.delete(categoryId!);

	redirect(303, "/dashboard/inventory/categories");
});
