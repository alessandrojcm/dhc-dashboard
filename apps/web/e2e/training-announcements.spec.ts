import { expect, type Locator, test } from "@playwright/test";
import { loginAsUser } from "./auth";
import { addClubDays, fetchE2EStatus } from "./e2eApi";
import {
	createMember,
	createTrainingAnnouncement,
	createUniqueEmail,
} from "./setupFunctions";

const tag = `training-e2e-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
const seededTitle = `E2E seeded ${tag} {{date}}`;
const createdTitle = `E2E created ${tag} {{date}}`;
const cleanups: Array<() => Promise<void>> = [];

let operatorEmail = "";
let operatorId = "";
let memberEmail = "";
let memberId = "";
let seeded: Awaited<ReturnType<typeof createTrainingAnnouncement>>;
let clubToday = "";

/** Elixir `Date.day_of_week/1` (Monday = 1 .. Sunday = 7) for an ISO date. */
function isoWeekday(isoDate: string): number {
	const jsDay = new Date(`${isoDate}T12:00:00Z`).getUTCDay();
	return jsDay === 0 ? 7 : jsDay;
}

/**
 * The bound `{{token}}` string of a `ui/template-input.svelte` field. The
 * field is a contenteditable textbox that shows each placeholder as a tag
 * labelled for humans ("Date"), so its text is not the value; rebuild the
 * value the way the component's own `read()` does.
 */
function templateValue(field: Locator): Promise<string> {
	return field.evaluate((root) => {
		const read = (node: Node): string => {
			if (node instanceof HTMLElement && node.dataset.placeholder)
				return node.dataset.placeholder;
			if (node.nodeType === Node.TEXT_NODE)
				return (node.textContent ?? "").replace(/\u00a0/g, " ");
			if (node instanceof HTMLBRElement) return "\n";
			return Array.from(node.childNodes).map(read).join("");
		};
		return read(root);
	});
}

test.describe("ALE-334 training announcements smoke", () => {
	test.beforeEach(async ({ page }) => {
		await page.setViewportSize({ width: 1280, height: 900 });
	});

	test.beforeAll(async () => {
		clubToday = (await fetchE2EStatus()).today;

		const operator = await createMember({
			email: createUniqueEmail("training-operator"),
			roles: new Set(["member", "committee_coordinator"]),
		});
		cleanups.push(() => operator.cleanUp());
		operatorEmail = operator.email;
		operatorId = operator.memberId;

		const member = await createMember({
			email: createUniqueEmail("training-member"),
		});
		cleanups.push(() => member.cleanUp());
		memberEmail = member.email;
		memberId = member.memberId;

		// Yesterday's weekday: the past delivery lands on yesterday (always in
		// the visible month grid) and the next occurrence a week out.
		seeded = await createTrainingAnnouncement({
			operatorMemberId: operatorId,
			title: seededTitle,
			weekday: isoWeekday(addClubDays(clubToday, -1)),
			postTime: "19:00",
		});
		cleanups.push(() => seeded.cleanUp());
	});

	test.afterAll(async () => {
		for (const cleanUp of cleanups.reverse()) {
			try {
				await cleanUp();
			} catch {
				/* best-effort: the per-run database is disposable */
			}
		}
	});

	test("operator creates from presets, suppresses a date, reads past evidence", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, operatorEmail);
		await page.goto("/dashboard/training-announcements");
		await expect(
			page.getByRole("heading", {
				name: "Training Announcements",
				exact: true,
			}),
		).toBeVisible();

		// Create from presets: the sheet opens on the roll-call copy. Exact
		// textbox roles: each template field also has a "<Label> placeholders"
		// group and "Insert … into <label>" buttons that a loose label matches.
		await page.getByRole("button", { name: "New announcement" }).click();
		const sheet = page.getByTestId("announcement-sheet");
		await expect(sheet).toBeVisible();
		const titleField = sheet.getByRole("textbox", {
			name: "Title",
			exact: true,
		});
		const messageField = sheet.getByRole("textbox", {
			name: "Message",
			exact: true,
		});
		await expect
			.poll(() => templateValue(titleField))
			.toBe("Roll call {{date}}");
		await expect
			.poll(() => templateValue(messageField))
			.toBe("Hey! It's {{weekday}}! Who is coming to training tonight? ⚔️");
		await titleField.fill(createdTitle);
		await sheet.getByRole("button", { name: "Create announcement" }).click();
		await expect(sheet).toBeHidden();
		await expect(
			page.getByRole("heading", { name: createdTitle }),
		).toBeVisible();

		const calendar = page.getByTestId("training-calendar");
		await expect(calendar).toBeVisible();

		// Suppress the seeded announcement's upcoming occurrence from its
		// inspector: the past chip carries the exact seeded thread name, so a
		// chip with our prefix but a different date is the future one.
		const prefix = new RegExp(`E2E seeded ${tag}`);
		const chips = calendar.getByText(prefix);
		await expect(chips.first()).toBeVisible({ timeout: 15_000 });
		const chipCount = await chips.count();
		let futureIndex = -1;
		for (let index = 0; index < chipCount; index += 1) {
			const text = await chips.nth(index).textContent();
			if (text && !text.includes(seeded.threadName)) {
				futureIndex = index;
				break;
			}
		}
		expect(futureIndex).toBeGreaterThanOrEqual(0);
		await chips.nth(futureIndex).click();

		const inspector = page.getByTestId("occurrence-inspector");
		await expect(inspector).toBeVisible();
		// A scheduled date previews the rendered post rather than a reason.
		await expect(inspector.getByTestId("inspector-message")).toBeVisible();
		await expect(inspector.getByTestId("not-sent-reason")).toHaveCount(0);
		await inspector.getByRole("button", { name: "Skip this date" }).click();

		const suppression = page.getByTestId("suppression-sheet");
		await expect(suppression).toBeVisible();
		// "First date" is the shared DatePicker trigger; a prefilled date
		// replaces its "Select a date" prompt.
		const firstDate = suppression.getByLabel("First date");
		await expect(firstDate).toBeVisible();
		await expect(firstDate).not.toContainText("Select a date");
		await suppression.getByRole("button", { name: "Skip these dates" }).click();
		await expect(suppression).toBeHidden();

		// The window refetch re-resolves the chip: scheduled becomes skipped.
		await expect(calendar.getByText("skipped").first()).toBeVisible({
			timeout: 15_000,
		});
		await inspector.getByRole("button", { name: "Close" }).first().click();
		await expect(inspector).toBeHidden();

		// Past evidence: the seeded delivery reads as posted with checkpoints.
		await calendar.getByText(seeded.threadName).first().click();
		await expect(inspector).toBeVisible();
		await expect(inspector.getByTestId("delivery-evidence")).toBeVisible();
		await expect(
			inspector.getByText("posted", { exact: true }).first(),
		).toBeVisible();
		await expect(inspector.getByText("Message posted")).toBeVisible();
		await expect(inspector.getByText("Thread attempts")).toBeVisible();
		await inspector.getByRole("button", { name: "Close" }).first().click();

		// The UI-created announcement never posted, so it deletes directly.
		const card = page
			.getByRole("article")
			.filter({ hasText: createdTitle })
			.first();
		await card.getByRole("button", { name: `Delete ${createdTitle}` }).click();
		await expect(page.getByRole("heading", { name: createdTitle })).toHaveCount(
			0,
		);
	});

	test("member without a management role sees no nav entry and is redirected", async ({
		page,
		context,
		browser,
	}) => {
		await loginAsUser(context, memberEmail);
		await page.goto("/dashboard");
		await expect(
			page.getByRole("link", { name: "Training Announcements", exact: true }),
		).toHaveCount(0);

		await page.goto("/dashboard/training-announcements");
		await expect(page).toHaveURL(`/dashboard/members/${memberId}`);

		// The operator keeps access in a second context for symmetry with the
		// role-gated specs.
		const operatorContext = await browser.newContext();
		const operatorPage = await operatorContext.newPage();
		await loginAsUser(operatorContext, operatorEmail);
		await operatorPage.goto("/dashboard");
		await expect(
			operatorPage.getByRole("link", {
				name: "Training Announcements",
				exact: true,
			}),
		).toBeVisible();
		await operatorContext.close();
	});
});
