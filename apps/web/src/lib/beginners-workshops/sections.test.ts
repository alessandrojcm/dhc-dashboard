import { describe, expect, it } from "vitest";
import {
	BEGINNERS_WORKSHOP_SECTIONS,
	isBeginnersWorkshopSection,
} from "./sections.js";

describe("Beginners' Workshop section routes", () => {
	it("has one dedicated URL per section, with Dashboard at the root", () => {
		expect(BEGINNERS_WORKSHOP_SECTIONS.map((section) => section.href)).toEqual([
			"/dashboard/beginners-workshop",
			"/dashboard/beginners-workshop/waitlist",
			"/dashboard/beginners-workshop/workshops",
			"/dashboard/beginners-workshop/email-templates",
			"/dashboard/beginners-workshop/invitable",
		]);
		for (const section of BEGINNERS_WORKSHOP_SECTIONS)
			expect(isBeginnersWorkshopSection(section.href)).toBe(true);
	});
	it("leaves console and assignment-scoped door pages outside the section shell", () => {
		for (const route of [
			null,
			"/dashboard/beginners-workshop/workshops/[workshopId]",
			"/dashboard/beginners-workshop/workshops/[workshopId]/door",
			"/dashboard/my-beginners-workshops",
			"/dashboard/beginners-workshop-other",
		])
			expect(isBeginnersWorkshopSection(route)).toBe(false);
	});
});
