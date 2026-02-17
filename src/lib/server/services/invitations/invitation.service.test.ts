import { describe, it, expect } from "vitest";
import { InvitationService } from "./invitation.service";
import {
	InvitationCreateSchema,
	InvitationStatusUpdateSchema,
} from "./invitation.service";
import * as v from "valibot";

describe("InvitationService", () => {
	describe("InvitationCreateSchema", () => {
		it("should validate valid invitation create data", () => {
			const validData = {
				email: "test@example.com",
				invitationType: "workshop" as const,
				userId: "550e8400-e29b-41d4-a716-446655440000",
				firstName: "John",
				lastName: "Doe",
				dateOfBirth: "1990-01-01",
				phoneNumber: "+353123456789",
			};

			const result = v.safeParse(InvitationCreateSchema, validData);
			expect(result.success).toBe(true);
		});

		it("should reject invalid email", () => {
			const invalidData = {
				email: "not-an-email",
				invitationType: "workshop",
				userId: "550e8400-e29b-41d4-a716-446655440000",
				firstName: "John",
				lastName: "Doe",
				dateOfBirth: "1990-01-01",
				phoneNumber: "+353123456789",
			};

			const result = v.safeParse(InvitationCreateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject invalid invitation type", () => {
			const invalidData = {
				email: "test@example.com",
				invitationType: "invalid",
				userId: "550e8400-e29b-41d4-a716-446655440000",
				firstName: "John",
				lastName: "Doe",
				dateOfBirth: "1990-01-01",
				phoneNumber: "+353123456789",
			};

			const result = v.safeParse(InvitationCreateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject invalid user ID", () => {
			const invalidData = {
				email: "test@example.com",
				invitationType: "workshop",
				userId: "not-a-uuid",
				firstName: "John",
				lastName: "Doe",
				dateOfBirth: "1990-01-01",
				phoneNumber: "+353123456789",
			};

			const result = v.safeParse(InvitationCreateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject empty first name", () => {
			const invalidData = {
				email: "test@example.com",
				invitationType: "workshop",
				userId: "550e8400-e29b-41d4-a716-446655440000",
				firstName: "",
				lastName: "Doe",
				dateOfBirth: "1990-01-01",
				phoneNumber: "+353123456789",
			};

			const result = v.safeParse(InvitationCreateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject empty last name", () => {
			const invalidData = {
				email: "test@example.com",
				invitationType: "workshop",
				userId: "550e8400-e29b-41d4-a716-446655440000",
				firstName: "John",
				lastName: "",
				dateOfBirth: "1990-01-01",
				phoneNumber: "+353123456789",
			};

			const result = v.safeParse(InvitationCreateSchema, invalidData);
			expect(result.success).toBe(false);
		});
	});

	describe("InvitationStatusUpdateSchema", () => {
		it("should validate valid status update data", () => {
			const validData = {
				invitationId: "550e8400-e29b-41d4-a716-446655440000",
				status: "accepted" as const,
			};

			const result = v.safeParse(InvitationStatusUpdateSchema, validData);
			expect(result.success).toBe(true);
		});

		it("should reject invalid invitation ID", () => {
			const invalidData = {
				invitationId: "not-a-uuid",
				status: "accepted",
			};

			const result = v.safeParse(InvitationStatusUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should reject invalid status", () => {
			const invalidData = {
				invitationId: "550e8400-e29b-41d4-a716-446655440000",
				status: "invalid",
			};

			const result = v.safeParse(InvitationStatusUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it("should accept all valid statuses", () => {
			const statuses = ["pending", "accepted", "expired", "revoked"];

			for (const status of statuses) {
				const data = {
					invitationId: "550e8400-e29b-41d4-a716-446655440000",
					status,
				};

				const result = v.safeParse(InvitationStatusUpdateSchema, data);
				expect(result.success).toBe(true);
			}
		});
	});

	describe("Service methods", () => {
		it("should have getInvitationInfo method", () => {
			expect(InvitationService.prototype.getInvitationInfo).toBeDefined();
			expect(typeof InvitationService.prototype.getInvitationInfo).toBe(
				"function",
			);
		});

		it("should have findById method", () => {
			expect(InvitationService.prototype.findById).toBeDefined();
			expect(typeof InvitationService.prototype.findById).toBe("function");
		});

		it("should have findMany method", () => {
			expect(InvitationService.prototype.findMany).toBeDefined();
			expect(typeof InvitationService.prototype.findMany).toBe("function");
		});

		it("should have create method", () => {
			expect(InvitationService.prototype.create).toBeDefined();
			expect(typeof InvitationService.prototype.create).toBe("function");
		});

		it("should have updateStatus method", () => {
			expect(InvitationService.prototype.updateStatus).toBeDefined();
			expect(typeof InvitationService.prototype.updateStatus).toBe("function");
		});

		it("should have validate method", () => {
			expect(InvitationService.prototype.validate).toBeDefined();
			expect(typeof InvitationService.prototype.validate).toBe("function");
		});
	});
});
