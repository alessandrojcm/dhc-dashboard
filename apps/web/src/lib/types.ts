import type { WorkshopCalendarItem } from "@dhc/api-client";
import type { Pathname } from "$app/types";
import type { Database } from "../database.types.ts";

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
	role: Set<string>;
};

export type NavigationGroup = {
	title: string;
	url: Pathname;
	items?: NavigationItem[];
	role: Set<string>;
};

export type NavData = {
	navMain: NavigationGroup[];
};
export type FetchAndCountResult<
	T extends keyof (Database["public"]["Tables"] | Database["public"]["Views"]),
> = {
	data: (
		| Database["public"]["Tables"]
		| Database["public"]["Views"]
	)[T]["Row"][];
	count: number;
};

export type MutationPayload<T extends keyof Database["public"]["Tables"]> =
	Database["public"]["Tables"][T]["Update"];

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

export type InventoryAttributeValue =
	| string
	| number
	| boolean
	| null
	| undefined;

export type InventoryAttributeDefinition = {
	name: string;
	label: string;
	required: boolean;
	type: "text" | "select" | "number" | "boolean";
	options?: string[];
	default_value?: InventoryAttributeValue;
};

export type InventoryAttributes = Record<string, InventoryAttributeValue>;

export type InventoryCategory =
	Database["public"]["Tables"]["equipment_categories"]["Row"] & {
		available_attributes: InventoryAttributeDefinition[];
	};

export type InventoryContainer =
	Database["public"]["Tables"]["containers"]["Row"];

export type InventoryItem =
	Database["public"]["Tables"]["inventory_items"]["Row"];

export type InventoryItemWithRelations = InventoryItem & {
	attributes: InventoryAttributes;
	container: {
		id: string | null;
		name: string | null;
		parent_container_id: string | null;
	};
	category: {
		id: string | null;
		name: string | null;
		available_attributes: InventoryAttributeDefinition[];
		attribute_schema: Database["public"]["Tables"]["equipment_categories"]["Row"]["attribute_schema"];
		description: string | null;
		created_at: string | null;
		updated_at: string | null;
	};
};

export type InventoryHistoryWithRelations =
	Database["public"]["Tables"]["inventory_history"]["Row"] & {
		item: {
			id: string;
			attributes: InventoryAttributes;
		} | null;
		old_container: {
			name: string;
		} | null;
		new_container: {
			name: string;
		} | null;
	};

export type ClubActivity =
	Database["public"]["Tables"]["club_activities"]["Row"];

export type ClubActivityInsert =
	Database["public"]["Tables"]["club_activities"]["Insert"];
export type ClubActivityUpdate =
	Database["public"]["Tables"]["club_activities"]["Update"];

export type ClubActivityWithInterest = ClubActivity & {
	interest_count?: { interest_count: number }[];
	user_interest?: { user_id: string }[];
	attendee_count?: { id: string; member_user_id: string; status: string }[];
};

export type ClubActivityWithRegistrations =
	Database["public"]["Tables"]["club_activities"]["Row"] &
		Omit<ClubActivityWithInterest, "attendee_count"> & {
			user_registrations: {
				member_user_id: number | null;
				status: Database["public"]["Enums"]["registration_status"];
			}[];
		};
