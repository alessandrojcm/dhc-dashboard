import { faker } from "@faker-js/faker";
import { expect, test } from "@playwright/test";
import dayjs from "dayjs";
import { createMember, getSupabaseServiceClient } from "./setupFunctions";
import { loginAsUser } from "./supabaseLogin";

test.describe("Pagination tests", () => {
	let member: Awaited<ReturnType<typeof createMember>>;
	const extraMembers: Array<Awaited<ReturnType<typeof createMember>>> = [];
	const waitlistEmails: string[] = [];
	const timestamp = Date.now();
	const randomSuffix = Math.random().toString(36).substring(2, 7);

	function buildEmail(prefix: string, index?: number) {
		const suffix = index !== undefined ? `-${index}` : "";
		return `${prefix}-${timestamp}-${randomSuffix}${suffix}@test.com`;
	}

	test.beforeAll(async () => {
		member = await createMember({
			email: buildEmail("test-pagination-admin"),
			roles: new Set(["member", "admin"]),
		});

		for (let i = 0; i < 12; i += 1) {
			const extraMember = await createMember({
				email: buildEmail("test-pagination-member", i),
				roles: new Set(["member"]),
			});
			extraMembers.push(extraMember);
		}

		const supabase = await getSupabaseServiceClient();
		for (let i = 0; i < 15; i += 1) {
			const email = buildEmail("test-pagination-waitlist", i);
			waitlistEmails.push(email);
			await supabase.rpc("insert_waitlist_entry", {
				first_name: faker.person.firstName(),
				last_name: faker.person.lastName(),
				email,
				date_of_birth: dayjs().subtract(20, "years").toISOString(),
				pronouns: "they/them",
				gender: "non-binary",
				phone_number: faker.phone.number(),
				medical_conditions: "None",
				social_media_consent: "no",
			});
		}
	});

	test.afterAll(async () => {
		await member.cleanUp();
		for (const extraMember of extraMembers) {
			await extraMember.cleanUp();
		}
		const supabase = await getSupabaseServiceClient();
		for (const email of waitlistEmails) {
			await supabase.from("waitlist").delete().eq("email", email);
		}
	});

	test("should correctly paginate the members table", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, member.email);

		await page.goto("/dashboard/members?tab=members");

		// Wait for table to load
		await expect(page.locator("table tbody tr")).toHaveCount(10, {
			timeout: 15000,
		});

		// Go to the next page - wait for pagination to be visible
		const nextButton = page.getByRole("button", { name: "Go to next page" });
		await expect(nextButton).toBeVisible({ timeout: 15000 });
		await expect(nextButton).toBeEnabled();
		await nextButton.focus();
		await page.keyboard.press("Enter");
		await page.waitForFunction(() => {
			return new URL(window.location.href).searchParams.get("page") === "1";
		});

		await expect(page.locator("table tbody tr")).toHaveCount(10);

		// Go back to the previous page
		await page.getByRole("button", { name: "Go to previous page" }).focus();
		await page.keyboard.press("Enter");
		await page.waitForFunction(() => {
			return new URL(window.location.href).searchParams.get("page") === "0";
		});
	});

	test("should correctly paginate the waitlist table", async ({
		page,
		context,
	}) => {
		await loginAsUser(context, member.email);

		await page.goto("/dashboard/beginners-workshop?tab=waitlist");

		// Wait for table to load
		await expect(page.locator("table tbody tr")).toHaveCount(10, {
			timeout: 15000,
		});

		// Go to the next page - wait for pagination to be visible
		const nextButton = page.getByRole("button", { name: "Go to next page" });
		await expect(nextButton).toBeVisible({ timeout: 15000 });
		await expect(nextButton).toBeEnabled();
		await nextButton.focus();
		await page.keyboard.press("Enter");
		await page.waitForFunction(() => {
			return new URL(window.location.href).searchParams.get("page") === "1";
		});

		await expect(page.locator("table tbody tr")).toHaveCount(10);

		// Go back to the previous page
		await page.getByRole("button", { name: "Go to previous page" }).focus();
		await page.keyboard.press("Enter");
		await page.waitForFunction(() => {
			return new URL(window.location.href).searchParams.get("page") === "0";
		});
	});
});
