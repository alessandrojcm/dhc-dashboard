import {
	beginnersWorkshopEmailTemplatesListQueryKey,
	type BeginnersWorkshopEmailTemplatesListResponse,
	type IntakeEmailTemplate,
} from "@dhc/api-client";
import { QueryClient } from "@tanstack/svelte-query";
import { expect, test } from "vitest";
import { render } from "vitest-browser-svelte";
import { INTAKE_EMAIL_TYPES } from "#lib/beginners-workshops/intake-emails/presentation.js";
import IntakeEmailTemplatesTestWrapper from "./intake-email-templates.test-wrapper.svelte";

const row = (
	emailType: IntakeEmailTemplate["emailType"],
	kind: IntakeEmailTemplate["kind"],
): IntakeEmailTemplate => ({
	emailType,
	kind,
	buttonLabel: kind === "action" ? "Pay for your place" : null,
	placeholders: [],
	subject: "Your Beginners' Workshop",
	body: { type: "doc", content: [] },
	updatedAt: "2026-10-01T09:30:00Z",
});

// Story 136: the type list itself says who receives each email.
test("the type list shows who receives each email", async () => {
	const queryClient = new QueryClient({
		defaultOptions: { queries: { retry: false, staleTime: Infinity } },
	});
	queryClient.setQueryData<BeginnersWorkshopEmailTemplatesListResponse>(
		beginnersWorkshopEmailTemplatesListQueryKey(),
		{
			data: [row("contact_pay", "action"), row("follow_up", "notice")],
		},
	);
	const screen = await render(IntakeEmailTemplatesTestWrapper, {
		queryClient,
	});

	const types = screen.getByRole("navigation", { name: "Email types" });
	await expect
		.element(types.getByRole("button", { name: /Contact — pay/ }))
		.toHaveTextContent(INTAKE_EMAIL_TYPES.contact_pay.recipients);
	await expect
		.element(types.getByRole("button", { name: /Follow-up/ }))
		.toHaveTextContent(INTAKE_EMAIL_TYPES.follow_up.recipients);
});
