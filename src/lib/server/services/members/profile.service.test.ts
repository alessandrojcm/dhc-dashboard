import { describe, it, expect } from "vitest";
import { ProfileService } from "./profile.service";

describe("ProfileService", () => {
	describe("Service methods", () => {
		it("should have updateProfile method", () => {
			expect(ProfileService.prototype.updateProfile).toBeDefined();
			expect(typeof ProfileService.prototype.updateProfile).toBe("function");
		});

		it("should have pauseSubscription method", () => {
			expect(ProfileService.prototype.pauseSubscription).toBeDefined();
			expect(typeof ProfileService.prototype.pauseSubscription).toBe(
				"function",
			);
		});

		it("should have resumeSubscription method", () => {
			expect(ProfileService.prototype.resumeSubscription).toBeDefined();
			expect(typeof ProfileService.prototype.resumeSubscription).toBe(
				"function",
			);
		});
	});
});
