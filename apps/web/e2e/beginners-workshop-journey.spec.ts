import { faker } from "@faker-js/faker";
import { expect, type Page, test } from "@playwright/test";
import dayjs from "dayjs";
import { loginAsUser } from "./auth";
import {
	addClubDays,
	deleteE2EFixture,
	deleteE2EFixtureUnlessReferenced,
	fetchE2EStatus,
	seedE2EScenario,
} from "./e2eApi";
import { gotoHydrated } from "./hydration";
import { stripeClient } from "./setupFunctions";

// ALE-398: the Beginners' Workshop flow end to end, from scheduling to
// Invitation. Named harness scenarios (`Dhc.E2EHarness.BeginnersWorkshops`)
// stand in for the clock — the 10:00 Batch pass and the workshop day — and
// for Stripe's payment UI: creation uses the real test API, while the SDK
// is stubbed to exercise mounting and the completion callback in place.
//
// A Batch takes the oldest waiting people first and each workshop seats
// one person, so every person here is seeded with a priority older than
// anyone else the run creates: the Batch contacts exactly them.

const WORKSHOPS_PATH = "/dashboard/beginners-workshop/workshops";
const INVITABLE_PATH = "/dashboard/beginners-workshop/invitable";

const tag = `${Date.now()}-${faker.string.alphanumeric(6).toLowerCase()}`;

// Fixtures the run seeded, torn down in `afterAll` whatever the tests did.
// The harness has no Beginners' Workshop teardown, so workshops (and the
// Carried Fee row, which outlives its person) stay in the disposable
// per-run database.
const memberIds: string[] = [];
const waitlistIds: string[] = [];

async function seedMember(
	role: "beginners_coordinator" | "member",
	firstName: string,
	lastName: string,
) {
	const member = await seedE2EScenario("member", {
		email: `bw-${lastName.toLowerCase()}-${tag}@test.com`,
		roles: role === "member" ? ["member"] : [role, "member"],
		firstName,
		lastName,
	});
	memberIds.push(member.userId);
	return member;
}

async function seedPerson(firstName: string, initialRegistrationDate: string) {
	const person = await seedE2EScenario("waitlist", {
		email: `bw-${firstName.toLowerCase()}-${tag}@example.com`,
		firstName,
		lastName: "Beginner",
		initialRegistrationDate,
	});
	waitlistIds.push(person.waitlistId);
	return person;
}

// An Invitation the handoff issued still names the Waitlist entry, so it
// goes first. None is the usual case: the journey deletes its own.
async function deleteInvitationOf(waitlistId: string) {
	const invitation = await seedE2EScenario("beginnersWorkshopInvitation", {
		waitlistId,
	}).catch(() => null);
	if (invitation) await deleteE2EFixture("invitation", invitation.invitationId);
}

async function pickDate(page: Page, label: string, isoDate: string) {
	const date = dayjs(isoDate);
	await page.getByRole("button", { name: label }).click();
	await page.getByLabel("Select a year").selectOption(date.format("YYYY"));
	await page.getByLabel("Select a month").selectOption(date.format("M"));
	await page
		.getByRole("button", { name: date.format("dddd, MMMM D,") })
		.click();
	await expect(page.getByLabel("Select a year")).toHaveCount(0);
}

async function stubEmbeddedCheckout(page: Page) {
	const sessions = new Set<string>();
	await page.exposeFunction("recordIntakeCheckoutSession", (id: string) => {
		if (!id.startsWith("cs_test_")) throw new Error("Expected test session");
		sessions.add(id);
	});
	await page.route("https://js.stripe.com/**", (route) =>
		route.fulfill({
			contentType: "application/javascript",
			body: `window.Stripe = () => ({
				initEmbeddedCheckout: async ({ clientSecret, onComplete }) => {
					if (!/^cs_test_.*_secret_/.test(clientSecret)) throw new Error('Expected test session');
					await window.recordIntakeCheckoutSession(clientSecret.split('_secret_')[0]);
					let button;
					return {
						mount(container) {
							button = document.createElement('button');
							button.textContent = 'Complete test payment';
							button.onclick = onComplete;
							container.append(button);
						},
						destroy() { button?.remove(); }
					};
				}
			});`,
		}),
	);
	return async () => {
		for (const id of sessions) {
			const session = await stripeClient.checkout.sessions.retrieve(id);
			if (session.status === "open")
				await stripeClient.checkout.sessions.expire(id);
		}
	};
}

test.describe("Beginners' Workshop journey", () => {
	let coordinatorEmail: string;
	let coordinatorId: string;

	test.beforeAll(async () => {
		const coordinator = await seedMember(
			"beginners_coordinator",
			"Coordinator",
			`Journey${faker.string.alpha(6)}`,
		);
		coordinatorEmail = coordinator.email;
		coordinatorId = coordinator.memberId;
	});

	test.afterAll(async () => {
		for (const waitlistId of waitlistIds) {
			await deleteInvitationOf(waitlistId);
			await deleteE2EFixture("waitlist", waitlistId);
		}
		// The coordinator scheduled workshops and the assistant is Staff, so
		// both usually stay (409 `still_referenced`).
		for (const memberId of memberIds)
			await deleteE2EFixtureUnlessReferenced("member", memberId);
	});

	test("embedded intake payment stays on the page and resumes its existing session", async ({
		page,
	}) => {
		const person = await seedPerson(
			`Embedded${faker.string.alpha(6)}`,
			"1999-01-01T09:00:00Z",
		);
		const workshop = await seedE2EScenario("beginnersWorkshop", {
			actorId: coordinatorId,
		});
		const batch = await seedE2EScenario("beginnersWorkshopBatch", {
			workshopId: workshop.workshopId,
		});
		expect(batch.contactedWaitlistIds).toEqual([person.waitlistId]);
		const link = await seedE2EScenario("beginnersWorkshopIntakeLink", {
			waitlistId: person.waitlistId,
		});
		const cleanupCheckout = await stubEmbeddedCheckout(page);
		try {
			await gotoHydrated(page, link.path);
			await expect(
				page.getByRole("button", { name: "Complete test payment" }),
			).toBeVisible();
			await expect(page).toHaveURL(new RegExp(`${link.path}$`));
			await gotoHydrated(page, link.path);
			await expect(
				page.getByRole("button", { name: "Complete test payment" }),
			).toBeVisible();
			const payment = await seedE2EScenario("beginnersWorkshopPayment", {
				waitlistId: person.waitlistId,
			});
			expect(payment.outcome).toBe("paid");
			await page.getByRole("button", { name: "Complete test payment" }).click();
			await expect(page).toHaveURL(
				new RegExp(`session_id=${payment.sessionId}$`),
			);
			await expect(
				page.getByRole("heading", { name: "Your place is confirmed" }),
			).toBeVisible();
		} finally {
			await cleanupCheckout();
		}
	});

	test("schedules, contacts, takes payment, checks in and invites", async ({
		page,
		context,
		browser,
	}) => {
		test.slow();
		const { today } = await fetchE2EStatus();
		const workshopDate = addClubDays(today, 14);
		const venue = `Journey Hall ${tag}`;
		const assistantLast = `Assistant${faker.string.alpha(6)}`;
		const assistantName = `Door ${assistantLast}`;
		const assistant = await seedMember("member", "Door", assistantLast);
		const personFirst = `Journey${faker.string.alpha(6)}`;
		const personName = `${personFirst} Beginner`;
		const person = await seedPerson(personFirst, "2000-01-01T09:00:00Z");

		// The coordinator schedules a workshop contacted from today and
		// assigns an assistant.
		await loginAsUser(context, coordinatorEmail);
		await gotoHydrated(page, WORKSHOPS_PATH);
		await page.getByRole("button", { name: "Schedule workshops" }).click();
		const dialog = page.getByRole("dialog", {
			name: "Schedule Beginners' Workshops",
		});
		await dialog.getByLabel("Venue").fill(venue);
		await dialog.getByLabel("Capacity").fill("1");
		await pickDate(page, "Workshop date 1", workshopDate);
		await pickDate(page, "Start offering places 1", today);
		await dialog.getByRole("combobox", { name: "Assistants" }).click();
		await page.getByPlaceholder("Search Members…").fill(assistantLast);
		await page.getByRole("option", { name: assistantName }).click();
		await page.keyboard.press("Escape");
		await expect(
			dialog.getByRole("list", { name: "Selected assistants" }),
		).toContainText(assistantName);
		await dialog.getByRole("button", { name: "Schedule workshop" }).click();
		await expect(
			page.getByText("Scheduled 1 Beginners' Workshop"),
		).toBeVisible();

		const consoleLink = `Manage workshop on ${workshopDate}`;
		const row = page
			.getByRole("listitem")
			.filter({ hasText: venue })
			.filter({ has: page.getByRole("link", { name: consoleLink }) });
		await expect(row).toContainText(assistantName);
		await row.getByRole("link", { name: consoleLink }).click();
		await expect(page).toHaveURL(
			/\/dashboard\/beginners-workshop\/workshops\/[0-9a-f-]+$/,
		);
		const workshopId = page.url().split("/").pop() ?? "";

		// The Batch pass at a fixed 10:00 contacts the person.
		const batch = await seedE2EScenario("beginnersWorkshopBatch", {
			workshopId,
		});
		expect(batch.contactedWaitlistIds).toEqual([person.waitlistId]);
		await gotoHydrated(
			page,
			`/dashboard/beginners-workshop/workshops/${workshopId}`,
		);
		await expect(
			page.getByRole("button", { name: `${personName} — Place offered` }),
		).toBeVisible();

		// The person opens their Intake link: Phoenix creates
		// a real embedded test-mode session, without leaving the Intake page.
		const link = await seedE2EScenario("beginnersWorkshopIntakeLink", {
			waitlistId: person.waitlistId,
		});
		const personContext = await browser.newContext();
		let cleanupCheckout = async () => {};
		try {
			const personPage = await personContext.newPage();
			cleanupCheckout = await stubEmbeddedCheckout(personPage);
			await gotoHydrated(personPage, link.path);
			await expect(
				personPage.getByRole("heading", {
					name: "Your place at the Beginners' Workshop",
				}),
			).toBeVisible();
			await expect(personPage.getByText(`Hi ${personFirst},`)).toBeVisible();
			await expect(
				personPage.getByRole("region", { name: "Secure payment" }),
			).toBeVisible();
			await expect(
				personPage.getByRole("button", { name: "Complete test payment" }),
			).toBeVisible();
			await expect(personPage).toHaveURL(new RegExp(`${link.path}$`));

			// Stripe completes the payment; the page shows paid.
			const payment = await seedE2EScenario("beginnersWorkshopPayment", {
				waitlistId: person.waitlistId,
			});
			expect(payment.outcome).toBe("paid");
			await personPage
				.getByRole("button", { name: "Complete test payment" })
				.click();
			await expect(personPage).toHaveURL(
				new RegExp(`session_id=${payment.sessionId}$`),
			);
			await expect(
				personPage.getByRole("heading", { name: "Your place is confirmed" }),
			).toBeVisible();
			await expect(personPage.getByText("€40.00 · paid")).toBeVisible();
		} finally {
			try {
				await cleanupCheckout();
			} finally {
				await personContext.close();
			}
		}

		// The workshop day: the assistant checks the person in and finishes
		// the workshop at the door.
		await seedE2EScenario("beginnersWorkshopDoorOpen", { workshopId });
		const assistantContext = await browser.newContext();
		try {
			const assistantPage = await assistantContext.newPage();
			await loginAsUser(assistantContext, assistant.email);
			await gotoHydrated(assistantPage, "/dashboard/my-beginners-workshops");
			await assistantPage
				.getByRole("listitem")
				.filter({ hasText: venue })
				.getByRole("link", { name: "Door view" })
				.click();
			await expect(
				assistantPage.getByRole("heading", { level: 1 }),
			).toBeVisible();
			await assistantPage
				.getByRole("button", { name: `Check in ${personName}` })
				.click();
			await expect(
				assistantPage.getByRole("progressbar", { name: "1 of 1 in" }),
			).toBeVisible();
			await expect(assistantPage.getByText("Everyone's in.")).toBeVisible();
			await assistantPage
				.getByRole("button", { name: "Finish workshop (0 did not attend)" })
				.click();
			const finish = assistantPage.getByRole("dialog", {
				name: "Finish workshop?",
			});
			await expect(finish.getByText("Everyone is checked in.")).toBeVisible();
			await finish.getByRole("button", { name: "Finish workshop" }).click();
			await expect(assistantPage.getByText("Workshop finished")).toBeVisible();
		} finally {
			await assistantContext.close();
		}

		// The coordinator sees the person as Invitable, invites them from
		// the console's attended list, and they leave Invitable.
		await gotoHydrated(page, INVITABLE_PATH);
		const invitableRow = page
			.getByRole("row")
			.filter({ hasText: person.email });
		await expect(invitableRow).toContainText(personName);

		await gotoHydrated(
			page,
			`/dashboard/beginners-workshop/workshops/${workshopId}`,
		);
		const attended = page.getByRole("region", { name: "Attended" });
		await expect(
			attended.getByRole("button", { name: `${personName} — Attended` }),
		).toBeVisible();
		// The dev server's TanStack Query Devtools button sits over the row's
		// right edge (see `screenshot.css`), so the button is pressed from
		// the keyboard.
		await attended.getByRole("button", { name: "Invite", exact: true }).focus();
		await page.keyboard.press("Enter");
		await expect(
			page.getByText(`Invitation sent to ${personName}`),
		).toBeVisible();
		await expect(
			attended.getByText("Membership invitation sent", { exact: true }),
		).toBeVisible();

		const invitation = await seedE2EScenario("beginnersWorkshopInvitation", {
			waitlistId: person.waitlistId,
		});
		try {
			expect(invitation).toMatchObject({
				status: "pending",
				invitationType: "beginners_workshop",
			});
			await gotoHydrated(page, INVITABLE_PATH);
			await expect(
				page.getByRole("link", { name: "Invite members", exact: true }),
			).toBeVisible();
			await expect(invitableRow).toHaveCount(0);
		} finally {
			// Other specs count every Invitation in the run.
			await deleteE2EFixture("invitation", invitation.invitationId);
		}
	});

	test("a Carried Fee holder confirms instead of paying", async ({
		page,
		context,
		browser,
	}) => {
		const { today } = await fetchE2EStatus();
		const holderFirst = `Holder${faker.string.alpha(6)}`;
		const holderName = `${holderFirst} Beginner`;
		const holder = await seedPerson(holderFirst, "1999-01-01T09:00:00Z");
		const fee = await seedE2EScenario("beginnersWorkshopCarriedFee", {
			waitlistId: holder.waitlistId,
		});
		expect(fee.status).toBe("held");
		const workshop = await seedE2EScenario("beginnersWorkshop", {
			actorId: coordinatorId,
			venue: `Carried Fee Hall ${tag}`,
			date: addClubDays(today, 21),
		});
		const batch = await seedE2EScenario("beginnersWorkshopBatch", {
			workshopId: workshop.workshopId,
		});
		expect(batch.contactedWaitlistIds).toEqual([holder.waitlistId]);
		const link = await seedE2EScenario("beginnersWorkshopIntakeLink", {
			waitlistId: holder.waitlistId,
		});

		const holderContext = await browser.newContext();
		try {
			const holderPage = await holderContext.newPage();
			await gotoHydrated(holderPage, link.path);
			await expect(
				holderPage.getByRole("heading", {
					name: "Confirm your place at the Beginners' Workshop",
				}),
			).toBeVisible();
			await expect(
				holderPage.getByRole("button", { name: "Pay for your place" }),
			).toHaveCount(0);
			await holderPage
				.getByRole("button", { name: "Confirm my place" })
				.click();
			await expect(
				holderPage.getByRole("heading", { name: "Your place is confirmed" }),
			).toBeVisible();
			await expect(
				holderPage.getByText(/Your workshop credit covers your place/),
			).toBeVisible();
		} finally {
			await holderContext.close();
		}

		await loginAsUser(context, coordinatorEmail);
		await gotoHydrated(
			page,
			`/dashboard/beginners-workshop/workshops/${workshop.workshopId}`,
		);
		await expect(
			page
				.getByRole("region", { name: "Confirmed places" })
				.getByRole("button", { name: `${holderName} — Paid` }),
		).toBeVisible();
	});
});
