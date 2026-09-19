import type { WorkshopCalendarItem } from "@dhc/api-client";
import type { Pathname } from "$app/types";

// Removed Schedule-X import - using vkurko/calendar now

export type UserData = {
	firstName: string;
	lastName: string;
	email: string;
	id: string;
	phoneNumber: string;
	customerId?: string;
};

export type NavigationItem = {
	title: string;
	url: Pathname;
	isActive?: boolean;
};

export type NavigationGroup = {
	title: string;
	url: Pathname;
	items?: NavigationItem[];
};

export type NavData = {
	navMain: NavigationGroup[];
};

export enum SocialMediaConsent {
	no = "no",
	yes_recognizable = "yes_recognizable",
	yes_unrecognizable = "yes_unrecognizable",
}

export type StripePaymentInfo = {
	customerId: string;
	annualSubscriptionPaymentIntendId: string;
	membershipSubscriptionPaymentIntendId: string;
};

export type PlanPricing = {
	complimentary?: boolean;
	proratedPrice: Dinero.DineroObject;
	proratedMonthlyPrice: Dinero.DineroObject;
	proratedAnnualPrice: Dinero.DineroObject;
	monthlyFee: Dinero.DineroObject;
	annualFee: Dinero.DineroObject;
	// Discounted amounts for recurring payments
	discountedMonthlyFee?: Dinero.DineroObject;
	discountedAnnualFee?: Dinero.DineroObject;
	// Discount information
	coupon?: string;
	discountPercentage?: number;
};

export type WorkshopCalendarEvent = {
	id: string;
	title: string;
	start: string;
	end: string;
	workshop: WorkshopCalendarItem;
	isInterested: boolean;
	isLoading: boolean;
	userId: string;
	handleEdit?: (workshop: WorkshopCalendarItem) => void;
};
