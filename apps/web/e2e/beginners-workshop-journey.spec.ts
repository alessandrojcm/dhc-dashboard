import { faker } from "@faker-js/faker";
import { expect, type Page, test } from "@playwright/test";
import dayjs from "dayjs";
import { loginAsUser } from "./auth";
import { stubEmbeddedCheckout } from "./beginners-workshop-checkout";
import {
	addClubDays,
	deleteE2EFixture,
	deleteE2EFixtureUnlessReferenced,
	fetchE2EStatus,
	seedE2EScenario,
} from "./e2eApi";
import { gotoHydrated } from "./hydration";

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

test.describe("Beginners' Workshop journey", () => {
	test.use({ timezoneId: "America/Los_Angeles" });
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

	test("saves explicit Dublin end times in winter and summer from a non-Dublin browser", async ({
		page,
		context,
	}) => {
		test.slow();
		const { today } = await fetchE2EStatus();
		const year = Number(today.slice(0, 4)) + 1;
		await loginAsUser(context, coordinatorEmail);

		for (const month of ["01", "07"]) {
			const workshopDate = `${year}-${month}-20`;
			const venue = `Dublin times ${month} ${tag}`;
			await gotoHydrated(page, WORKSHOPS_PATH);
			await page.getByRole("button", { name: "Schedule workshops" }).click();
			const dialog = page.getByRole("dialog", {
				name: "Schedule Beginners' Workshops",
			});
			await dialog.getByLabel("Venue", { exact: true }).fill(venue);
			await pickDate(page, "Workshop date 1", workshopDate);
			await dialog.getByLabel("Start time", { exact: true }).fill("18:30");
			await expect(dialog.getByLabel("End time", { exact: true })).toHaveValue(
				"",
			);
			await dialog.getByLabel("End time", { exact: true }).fill("18:30");
			await dialog
				.getByRole("button", { name: "Schedule workshop", exact: true })
				.click();
			await expect(dialog.getByText(/end.*after.*start/i)).toBeVisible();
			await dialog.getByLabel("End time", { exact: true }).fill("20:15");
			await dialog
				.getByRole("button", { name: "Schedule workshop", exact: true })
				.click();
			await expect(dialog).not.toBeVisible();

			const row = page.getByRole("listitem").filter({ hasText: venue });
			await expect(row).toContainText(/18:30.*20:15/);
			await row
				.getByRole("link", { name: `Manage workshop on ${workshopDate}` })
				.click();
			await expect(page).toHaveURL(
				/\/dashboard\/beginners-workshop\/workshops\/[0-9a-f-]+$/,
			);
			const workshopUrl = page.url();
			await page
				.getByRole("button", { name: "Reschedule", exact: true })
				.click();
			const reschedule = page.getByRole("dialog", { name: /^Reschedule / });
			await expect(
				reschedule.getByLabel("End time", { exact: true }),
			).toHaveValue("20:15");
			await reschedule.getByLabel("Start", { exact: true }).fill("19:00");
			await reschedule.getByLabel("End time", { exact: true }).fill("21:10");
			await reschedule
				.getByRole("button", { name: "Reschedule", exact: true })
				.click();
			await expect(reschedule).not.toBeVisible();
			await gotoHydrated(page, workshopUrl);
			await expect(page.getByText(/19:00.*21:10/)).toBeVisible();
		}
	});

	// ALE-441: manual destinations on schedule, a destination-only change
	// that is not a reschedule, and directions on the person's Intake page.
	test("shares a destination across scheduled dates, saves a destination-only change and gives the person directions", async ({
		page,
		context,
		browser,
	}) => {
		test.slow();
		const { today } = await fetchE2EStatus();
		const firstDate = addClubDays(today, 21);
		const secondDate = addClubDays(today, 28);
		const venue = `Destination Hall ${tag}`;
		const personFirst = `Directions${faker.string.alpha(6)}`;
		const person = await seedPerson(personFirst, "1998-01-01T09:00:00Z");

		await loginAsUser(context, coordinatorEmail);
		await gotoHydrated(page, WORKSHOPS_PATH);
		await page.getByRole("button", { name: "Schedule workshops" }).click();
		const dialog = page.getByRole("dialog", {
			name: "Schedule Beginners' Workshops",
		});
		await dialog.getByLabel("Venue", { exact: true }).fill(venue);
		await dialog
			.getByLabel("Destination name")
			.fill("National Basketball Arena");
		await dialog
			.getByLabel("Destination address")
			.fill("Tymon Park, Dublin 6w");
		await dialog.getByLabel("Capacity").fill("1");
		await dialog.getByLabel("Start time", { exact: true }).fill("18:30");
		await dialog.getByLabel("End time", { exact: true }).fill("20:15");
		await pickDate(page, "Workshop date 1", firstDate);
		await pickDate(page, "Start offering places 1", today);
		await dialog.getByRole("button", { name: "Add another date" }).click();
		await pickDate(page, "Workshop date 2", secondDate);
		await dialog
			.getByRole("button", { name: "Schedule 2 workshops", exact: true })
			.click();
		await expect(
			page.getByText("Scheduled 2 Beginners' Workshops"),
		).toBeVisible();

		const open = async (date: string) => {
			await gotoHydrated(page, WORKSHOPS_PATH);
			const link = `Manage workshop on ${date}`;
			await page
				.getByRole("listitem")
				.filter({ hasText: venue })
				.getByRole("link", { name: link })
				.click();
			await expect(page).toHaveURL(
				/\/dashboard\/beginners-workshop\/workshops\/[0-9a-f-]+$/,
			);
			return page.url().split("/").pop() ?? "";
		};

		const workshopId = await open(firstDate);
		await expect(
			page.getByText("National Basketball Arena · Tymon Park, Dublin 6w"),
		).toBeVisible();
		const batch = await seedE2EScenario("beginnersWorkshopBatch", {
			workshopId,
		});
		expect(batch.contactedWaitlistIds).toEqual([person.waitlistId]);
		await gotoHydrated(
			page,
			`/dashboard/beginners-workshop/workshops/${workshopId}`,
		);

		// Only the destination changes, so it is saved without emailing.
		await page.getByRole("button", { name: "Reschedule", exact: true }).click();
		const reschedule = page.getByRole("dialog", { name: /^Reschedule / });
		await expect(reschedule.getByLabel("Destination name")).toHaveValue(
			"National Basketball Arena",
		);
		await reschedule
			.getByLabel("Destination address")
			.fill("Tymon Road, Dublin 6w");
		await reschedule
			.getByLabel("Google Maps directions link")
			.fill("https://evil.example.com/maps");
		await expect(reschedule.getByTestId("reschedule-warning")).toHaveText(
			"No emails will be sent: only the destination details change.",
		);
		await reschedule.getByRole("button", { name: "Save destination" }).click();
		// Phoenix refuses the link on its field; the other values stay.
		await expect(
			reschedule.getByText("Directions link must be a Google Maps link"),
		).toBeVisible();
		await expect(reschedule.getByLabel("Destination address")).toHaveValue(
			"Tymon Road, Dublin 6w",
		);
		await reschedule
			.getByLabel("Google Maps directions link")
			.fill("https://maps.app.goo.gl/AbCdEf");
		await reschedule.getByRole("button", { name: "Save destination" }).click();
		await expect(page.getByText("Destination details saved")).toBeVisible();
		await expect(reschedule).not.toBeVisible();
		await gotoHydrated(
			page,
			`/dashboard/beginners-workshop/workshops/${workshopId}`,
		);
		await expect(
			page.getByText("National Basketball Arena · Tymon Road, Dublin 6w"),
		).toBeVisible();
		await expect(page.getByText(/18:30.*20:15/)).toBeVisible();

		// The other date owns its own copy.
		await open(secondDate);
		await expect(
			page.getByText("National Basketball Arena · Tymon Park, Dublin 6w"),
		).toBeVisible();

		// The person sees the destination and a directions link, which never
		// carries their private link.
		const link = await seedE2EScenario("beginnersWorkshopIntakeLink", {
			waitlistId: person.waitlistId,
		});
		const personContext = await browser.newContext();
		let cleanupCheckout = async () => {};
		try {
			const personPage = await personContext.newPage();
			cleanupCheckout = await stubEmbeddedCheckout(personPage);
			await gotoHydrated(personPage, link.path);
			const details = personPage.getByRole("list", { name: "Workshop" });
			await expect(details).toContainText(venue);
			await expect(details).toContainText(
				"National Basketball Arena · Tymon Road, Dublin 6w",
			);
			const directions = details.getByRole("link", { name: "Get directions" });
			await expect(directions).toHaveAttribute(
				"href",
				"https://maps.app.goo.gl/AbCdEf",
			);
			await expect(directions).toHaveAttribute("rel", "noopener noreferrer");
		} finally {
			try {
				await cleanupCheckout();
			} finally {
				await personContext.close();
			}
		}
	});

	// ALE-442: Google venue search through the real Phoenix lookup (answered by
	// the E2E server's synthetic Places catalogue): only the Place ID is saved
	// on schedule and replaced by a destination-only change; the person sees
	// the venue label, never Google's text, with place-bound directions.
	test("schedules with a chosen Google place, replaces it without emailing and gives the person place-bound directions", async ({
		page,
		context,
		browser,
	}) => {
		test.slow();
		const { today } = await fetchE2EStatus();
		const date = addClubDays(today, 35);
		const venue = `Google Hall ${tag}`;
		const person = await seedPerson(
			`Places${faker.string.alpha(6)}`,
			"1997-01-01T09:00:00Z",
		);

		await loginAsUser(context, coordinatorEmail);
		await gotoHydrated(page, WORKSHOPS_PATH);
		await page.getByRole("button", { name: "Schedule workshops" }).click();
		const dialog = page.getByRole("dialog", {
			name: "Schedule Beginners' Workshops",
		});
		await dialog.getByLabel("Venue", { exact: true }).fill(venue);

		const search = dialog.getByRole("combobox", { name: "Search Google Maps" });
		await search.pressSequentially("Synthetic Fencing");
		await expect(dialog.getByRole("option")).toHaveCount(2);
		await search.press("ArrowDown");
		await search.press("Enter");
		const selected = dialog.getByRole("region", { name: "Selected place" });
		await expect(selected).toContainText("Synthetic Fencing Hall");
		await expect(selected).toContainText("Google Maps · Example Venue Guide");
		await expect(
			dialog.getByRole("textbox", { name: "Destination name", exact: true }),
		).toHaveValue("");
		// Choosing a place does not submit the dialog.
		await expect(dialog).toBeVisible();

		await dialog.getByLabel("Capacity").fill("1");
		await dialog.getByLabel("Start time", { exact: true }).fill("18:30");
		await dialog.getByLabel("End time", { exact: true }).fill("20:15");
		await pickDate(page, "Workshop date 1", date);
		await pickDate(page, "Start offering places 1", today);
		await dialog
			.getByRole("button", { name: "Schedule workshop", exact: true })
			.click();
		await expect(
			page.getByText("Scheduled 1 Beginners' Workshop"),
		).toBeVisible();

		await gotoHydrated(page, WORKSHOPS_PATH);
		await page
			.getByRole("listitem")
			.filter({ hasText: venue })
			.getByRole("link", { name: `Manage workshop on ${date}` })
			.click();
		await expect(page).toHaveURL(
			/\/dashboard\/beginners-workshop\/workshops\/[0-9a-f-]+$/,
		);
		const workshopId = page.url().split("/").pop() ?? "";
		// No Google text is stored, so the console shows none.
		await expect(page.getByText(venue).first()).toBeVisible();
		await expect(page.getByText("Synthetic Fencing Hall")).toHaveCount(0);
		await expect(page.getByTestId("destination-attribution")).toHaveCount(0);
		const batch = await seedE2EScenario("beginnersWorkshopBatch", {
			workshopId,
		});
		expect(batch.contactedWaitlistIds).toEqual([person.waitlistId]);
		await gotoHydrated(
			page,
			`/dashboard/beginners-workshop/workshops/${workshopId}`,
		);

		// Replacing the place at the same venue is a destination-only change.
		await page.getByRole("button", { name: "Reschedule", exact: true }).click();
		const reschedule = page.getByRole("dialog", { name: /^Reschedule / });
		await expect(
			reschedule.getByRole("region", { name: "Selected place" }),
		).toContainText("Google Maps place selected");
		const replace = reschedule.getByRole("combobox", {
			name: "Replace with another place",
		});
		await replace.pressSequentially("Annex");
		await reschedule
			.getByRole("option", { name: /Synthetic Fencing Annex/ })
			.click();
		await expect(
			reschedule.getByRole("region", { name: "Selected place" }),
		).toContainText("Synthetic Fencing Annex");
		await expect(reschedule.getByTestId("reschedule-warning")).toHaveText(
			"No emails will be sent: only the destination details change.",
		);
		await reschedule.getByRole("button", { name: "Save destination" }).click();
		await expect(page.getByText("Destination details saved")).toBeVisible();

		const link = await seedE2EScenario("beginnersWorkshopIntakeLink", {
			waitlistId: person.waitlistId,
		});
		const personContext = await browser.newContext();
		let cleanupCheckout = async () => {};
		try {
			const personPage = await personContext.newPage();
			cleanupCheckout = await stubEmbeddedCheckout(personPage);
			await gotoHydrated(personPage, link.path);
			const details = personPage.getByRole("list", { name: "Workshop" });
			await expect(details).toContainText(venue);
			await expect(details).not.toContainText("Synthetic Fencing");
			await expect(details.getByTestId("destination-attribution")).toHaveCount(
				0,
			);
			const directions = details.getByRole("link", { name: "Get directions" });
			await expect(directions).toHaveAttribute(
				"href",
				`https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(venue)}&destination_place_id=e2e_place_annex`,
			);
			await expect(directions).toHaveAttribute("referrerpolicy", "no-referrer");
			expect(await directions.getAttribute("href")).not.toContain(link.path);
		} finally {
			try {
				await cleanupCheckout();
			} finally {
				await personContext.close();
			}
		}
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
		await dialog.getByLabel("Start time", { exact: true }).fill("18:30");
		await dialog.getByLabel("End time", { exact: true }).fill("20:15");
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
		await expect(row).toContainText(/18:30.*20:15/);
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
		const people = page.getByRole("region", { name: "People", exact: true });
		await expect(
			people.getByRole("button", { name: `${personName} — Attended` }),
		).toBeVisible();
		// The dev server's TanStack Query Devtools button sits over the row's
		// right edge (see `screenshot.css`), so the button is pressed from
		// the keyboard.
		await people.getByRole("button", { name: "Invite", exact: true }).focus();
		await page.keyboard.press("Enter");
		await expect(
			page.getByText(`Invitation sent to ${personName}`),
		).toBeVisible();
		await expect(
			people.getByText("Membership invitation sent", { exact: true }),
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
				.getByRole("region", { name: "People", exact: true })
				.getByRole("button", { name: `${holderName} — Paid` }),
		).toBeVisible();
	});
});
