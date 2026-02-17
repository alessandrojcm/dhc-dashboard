import { describe, it, expect, beforeAll, afterAll } from "vitest";
import {
	MemberService,
	MemberUpdateSchema,
	type UpdateMemberDataArgs,
} from "./member.service";
import { getKyselyClient } from "../shared";
import type { Kysely, KyselyDatabase } from "../shared";
import type { Session } from "@supabase/supabase-js";
import { createMember } from "../../../../../e2e/setupFunctions";
import { faker } from "@faker-js/faker/locale/en_IE";
import * as v from "valibot";
import "dotenv/config";

// Database connection from environment
const LOCAL_DB_URL =
	process.env.DATABASE_URL ||
	"postgresql://postgres:postgres@localhost:54322/postgres";

// Test data - will be populated from setup
let testUserId: string;
let testUserProfileId: string;
let testSession: Session;
let cleanupFn: () => Promise<void>;
let db: Kysely<KyselyDatabase>;

describe("MemberService", () => {
	describe("MemberUpdateSchema", () => {
		it("should validate valid member update data", () => {
			const validData = {
				firstName: "John",
				lastName: "Doe",
				phoneNumber: "+353123456789",
				dateOfBirth: new Date("1990-01-01"),
				pronouns: "he/him",
				gender: "male",
				medicalConditions: "None",
				nextOfKin: "Jane Doe",
				nextOfKinNumber: "+353987654321",
				preferredWeapon: ["longsword"],
				insuranceFormSubmitted: true,
				socialMediaConsent: "yes",
			};

			const result = v.safeParse(MemberUpdateSchema, validData);
			expect(result.success).toBe(true);
		});

		it("should reject invalid first name", () => {
			const invalidData = {
				firstName: "",
				lastName: "Doe",
				dateOfBirth: new Date("1990-01-01"),
			};

			const result = v.safeParse(MemberUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject invalid last name", () => {
			const invalidData = {
				firstName: "John",
				lastName: "",
				dateOfBirth: new Date("1990-01-01"),
			};

			const result = v.safeParse(MemberUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject future date of birth", () => {
			const futureDate = new Date();
			futureDate.setFullYear(futureDate.getFullYear() + 1);

			const invalidData = {
				firstName: "John",
				lastName: "Doe",
				dateOfBirth: futureDate,
			};

			const result = v.safeParse(MemberUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});
	});

	describe("Database Integration Tests", () => {
		beforeAll(async () => {
			db = getKyselyClient(LOCAL_DB_URL);

			// Create a test member using the e2e setup function
			const email = faker.internet.email().toLowerCase();
			const member = await createMember({ email });

			testUserId = member.userId!;
			testUserProfileId = member.profileId;
			testSession = member.session!;
			cleanupFn = member.cleanUp;

			console.log("Created test member:", { testUserId, testUserProfileId });
		});

		afterAll(async () => {
			// Clean up the test member
			if (cleanupFn) {
				await cleanupFn();
			}
			await db.destroy();
		});

		describe("findById", () => {
			it("should fetch member data by user ID", async () => {
				const service = new MemberService(db, testSession);
				const member = await service.findById(testUserId);

				expect(member).toBeDefined();
				expect(member.first_name).toBeDefined();
				expect(member.last_name).toBeDefined();
			});

			it("should throw error for non-existent user", async () => {
				// Use the same session but query a non-existent user ID
				const service = new MemberService(db, testSession);

				await expect(
					service.findById("00000000-0000-0000-0000-000000000000"),
				).rejects.toThrow();
			});
		});

		describe("updateWithArgs - preferred_weapon", () => {
			it("should update preferred_weapon with single value", async () => {
				const service = new MemberService(db, testSession);

				// Get current state
				const before = await service.findById(testUserId);
				console.log(
					"Before update - preferred_weapon:",
					before.preferred_weapon,
				);

				// Update with longsword
				const args: UpdateMemberDataArgs = {
					user_uuid: testUserId,
					p_preferred_weapon: ["longsword"],
				};

				const result = await service.updateWithArgs(args);
				console.log(
					"After update - preferred_weapon:",
					result.preferred_weapon,
				);

				expect(result.preferred_weapon).toContain("longsword");
			});

			it("should update preferred_weapon with multiple values", async () => {
				const service = new MemberService(db, testSession);

				const args: UpdateMemberDataArgs = {
					user_uuid: testUserId,
					p_preferred_weapon: ["longsword", "sword_and_buckler"],
				};

				const result = await service.updateWithArgs(args);
				console.log(
					"After update - preferred_weapon:",
					result.preferred_weapon,
				);

				expect(result.preferred_weapon).toContain("longsword");
				expect(result.preferred_weapon).toContain("sword_and_buckler");
			});

			it("should persist preferred_weapon after update", async () => {
				const service = new MemberService(db, testSession);

				// Set to longsword
				await service.updateWithArgs({
					user_uuid: testUserId,
					p_preferred_weapon: ["longsword"],
				});

				// Fetch again to verify persistence
				const member = await service.findById(testUserId);
				console.log(
					"Fetched after update - preferred_weapon:",
					member.preferred_weapon,
				);

				expect(member.preferred_weapon).toContain("longsword");
			});
		});

		describe("update - full profile update", () => {
			it("should update member profile with all fields", async () => {
				const service = new MemberService(db, testSession);

				const input = {
					firstName: "TestFirst",
					lastName: "TestLast",
					phoneNumber: "+353123456789",
					dateOfBirth: new Date("1990-01-15"),
					pronouns: "they/them",
					medicalConditions: "None",
					nextOfKin: "Test Kin",
					nextOfKinNumber: "+353987654321",
					preferredWeapon: ["longsword"],
					insuranceFormSubmitted: true,
				};

				const result = await service.update(testUserId, input);

				expect(result.first_name).toBe("TestFirst");
				expect(result.last_name).toBe("TestLast");
				expect(result.phone_number).toBe("+353123456789");
				expect(result.pronouns).toBe("they/them");
				expect(result.preferred_weapon).toContain("longsword");
			});

			it("should update only preferredWeapon field", async () => {
				const service = new MemberService(db, testSession);

				// Get current data first
				const current = await service.findById(testUserId);

				const input = {
					firstName: current.first_name!,
					lastName: current.last_name!,
					dateOfBirth: new Date(current.date_of_birth!),
					preferredWeapon: ["sword_and_buckler"],
				};

				const result = await service.update(testUserId, input);

				expect(result.preferred_weapon).toContain("sword_and_buckler");
			});
		});
	});
});
