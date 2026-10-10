import fixtures from "@dhc/email-templates/fixtures/intake-email-measure.json";
import type {
	IntakeEmailDocument,
	IntakeEmailPlaceholder,
	IntakeEmailTemplate,
	IntakeEmailType,
} from "@dhc/api-client";
import { vIntakeEmailDocument } from "@dhc/api-client";
import * as v from "valibot";
import { describe, expect, test, vi } from "vitest";
import { page, userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import IntakeEmailTemplateEditor from "./intake-email-template-editor.svelte";

// SAFETY: renderer_test.exs runs the same fixtures through Phoenix, so every
// fixture `emailType` is an Intake Email type.
const fixtureType = (type: string) => type as IntakeEmailType;

// SAFETY: renderer_test.exs pins the fixture's `placeholders` table to
// Phoenix's EmailType table, and every key is an email type.
const PLACEHOLDERS = fixtures.placeholders as Record<
	IntakeEmailType,
	IntakeEmailPlaceholder[]
>;

const doc = (
	...content: NonNullable<IntakeEmailDocument["content"]>
): IntakeEmailDocument => ({
	type: "doc",
	content,
});
const p = (...content: object[]) => ({ type: "paragraph", content });
const t = (text: string) => ({ type: "text", text });
const ph = (name: string) => ({ type: "placeholder", attrs: { name } });

const ACTION_TYPES = new Set<IntakeEmailType>([
	"contact_pay",
	"contact_confirm",
	"place_confirmed_paid",
	"place_confirmed_carried",
	"pre_workshop",
	"rescheduled",
]);

function template(
	emailType: IntakeEmailType,
	overrides: Partial<IntakeEmailTemplate> = {},
): IntakeEmailTemplate {
	const action = ACTION_TYPES.has(emailType);
	return {
		emailType,
		kind: action ? "action" : "notice",
		buttonLabel: action ? "Pay for your place" : null,
		placeholders: PLACEHOLDERS[emailType],
		subject: "Your Beginners' Workshop",
		body: doc(p(t("Hi"))),
		updatedAt: "2026-10-01T09:30:00Z",
		...overrides,
	};
}

async function mount(value: IntakeEmailTemplate) {
	const onsave = vi.fn();
	const screen = await render(IntakeEmailTemplateEditor, {
		template: value,
		onsave,
	});
	return { screen, onsave };
}

const counter = () => page.getByTestId("intake-email-counter");
const saveButton = () => page.getByRole("button", { name: "Save template" });
const counterText = (length: number) =>
	`${length.toLocaleString("en-IE")} / 2,000`;

describe("the counter against the shared measure fixtures", () => {
	for (const fixture of fixtures.cases) {
		test(`counts: ${fixture.name}`, async () => {
			const emailType = fixtureType(fixture.emailType);
			await mount(
				template(emailType, {
					body: v.parse(vIntakeEmailDocument, fixture.body),
				}),
			);

			await expect
				.element(counter())
				.toHaveTextContent(counterText(fixture.expectedLength));
			if (fixture.fits) await expect.element(saveButton()).toBeEnabled();
			else await expect.element(saveButton()).toBeDisabled();

			// Edit through the editor: a first-name chip adds its 40-character
			// maximum, and deleting it leaves exactly the fixture document, so
			// the count now comes from the editor's own JSON.
			await page
				.getByRole("button", { name: "Insert first name into message" })
				.click();
			await expect
				.element(counter())
				.toHaveTextContent(
					counterText(fixture.expectedLength + fixtures.maxima.firstName),
				);
			if (fixture.expectedLength + fixtures.maxima.firstName > 2000)
				await expect.element(saveButton()).toBeDisabled();

			await userEvent.keyboard("{Backspace}");
			await expect
				.element(counter())
				.toHaveTextContent(counterText(fixture.expectedLength));
		});
	}

	for (const fixture of fixtures.refusals) {
		test(`refuses: ${fixture.name}`, async () => {
			await mount(
				template(fixtureType(fixture.emailType), {
					body: v.parse(vIntakeEmailDocument, fixture.body),
				}),
			);

			await expect
				.element(page.getByText("Not available in this email"))
				.toBeVisible();
			for (const name of fixture.placeholders)
				await expect
					.element(page.getByText(`{{${name}}} can't be filled`))
					.toBeVisible();
			await expect.element(saveButton()).toBeDisabled();
		});
	}
});

describe("placeholder chips", () => {
	test("only the email type's own placeholders can be inserted", async () => {
		await mount(template("withdrawn_forfeited"));

		const body = page.getByRole("group", { name: "Message placeholders" });
		await expect
			.element(body.getByRole("button", { name: /^Insert / }))
			.toHaveAccessibleName("Insert first name into message");
		await expect
			.element(page.getByRole("button", { name: "Insert venue into message" }))
			.not.toBeInTheDocument();
		await expect
			.element(page.getByRole("button", { name: "Insert date into subject" }))
			.not.toBeInTheDocument();
	});

	test("a body chip is deleted whole, never half-deleted into text", async () => {
		await mount(
			template("follow_up", { body: doc(p(ph("firstName"), t("!"))) }),
		);

		const message = page.getByRole("textbox", { name: "Message" });
		await expect
			.element(message.getByLabelText("First name placeholder"))
			.toBeVisible();
		await expect.element(counter()).toHaveTextContent(counterText(48));

		// Caret after the chip, then one Backspace.
		await message.getByText("!").click();
		await userEvent.keyboard("{Home}{ArrowRight}{Backspace}");

		await expect
			.element(message.getByLabelText("First name placeholder"))
			.not.toBeInTheDocument();
		await expect.element(message).toHaveTextContent(/^!$/);
		await expect.element(counter()).toHaveTextContent(counterText(8));
	});

	test("saves the Phoenix placeholder node and subject tokens", async () => {
		const { onsave } = await mount(
			template("follow_up", { subject: "Thanks,", body: doc(p(t("Hi "))) }),
		);

		await page
			.getByRole("textbox", { name: "Message" })
			.getByText("Hi")
			.click();
		await userEvent.keyboard("{End}");
		await page
			.getByRole("button", { name: "Insert first name into message" })
			.click();

		const subject = page.getByRole("textbox", { name: "Subject" });
		await subject.click();
		await userEvent.keyboard("{End}");
		await page
			.getByRole("button", { name: "Insert first name into subject" })
			.click();
		await expect
			.element(subject.getByLabelText("First name placeholder"))
			.toBeVisible();

		await saveButton().click();

		expect(onsave).toHaveBeenCalledWith({
			subject: "Thanks,{{firstName}}",
			body: doc(p(t("Hi "), ph("firstName"))),
		});
	});

	test("a subject token the type can't fill keeps Save disabled", async () => {
		await mount(
			template("withdrawn_forfeited", { subject: "See you {{date}}" }),
		);

		await expect
			.element(page.getByText("{{date}} can't be filled"))
			.toBeVisible();
		await expect.element(saveButton()).toBeDisabled();
	});
});

describe("the app-added button", () => {
	test("action emails show it as a fixed footer", async () => {
		await mount(template("contact_pay"));

		const footer = page.getByRole("note", { name: "Button added by the app" });
		await expect.element(footer).toHaveTextContent("Pay for your place");
		await expect.element(footer.getByRole("textbox")).not.toBeInTheDocument();
	});

	test("notices have no button", async () => {
		await mount(template("declined"));

		await expect
			.element(page.getByRole("note", { name: "Button added by the app" }))
			.not.toBeInTheDocument();
	});
});

describe("Phoenix refusals", () => {
	test("show the problem detail and field messages", async () => {
		await render(IntakeEmailTemplateEditor, {
			template: template("declined"),
			onsave: vi.fn(),
			problem: {
				detail: "The template uses a placeholder this email can't fill",
				code: "placeholder_not_allowed",
				fields: [
					{
						field: "body",
						messages: ["uses {{venue}}, which this email can't fill"],
					},
				],
			},
		});

		await expect
			.element(
				page.getByText("The template uses a placeholder this email can't fill"),
			)
			.toBeVisible();
		await expect
			.element(
				page.getByText("Message uses {{venue}}, which this email can't fill"),
			)
			.toBeVisible();
	});
});
