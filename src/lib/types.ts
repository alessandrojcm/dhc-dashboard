import type { Database } from '$database';
import type { KyselifyDatabase } from 'kysely-supabase';
import type Stripe from 'stripe';
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
	url: string;
	isActive?: boolean;
	role: Set<string>;
};

export type NavigationGroup = {
	title: string;
	url: string;
	items?: NavigationItem[];
	role: Set<string>;
};

export type NavData = {
	navMain: NavigationGroup[];
};
export type FetchAndCountResult<
	T extends keyof (Database['public']['Tables'] | Database['public']['Views'])
> = {
	data: (Database['public']['Tables'] | Database['public']['Views'])[T]['Row'][];
	count: number;
};

export type MutationPayload<T extends keyof Database['public']['Tables']> =
	Database['public']['Tables'][T]['Update'];

export enum SocialMediaConsent {
	no = 'no',
	yes_recognizable = 'yes_recognizable',
	yes_unrecognizable = 'yes_unrecognizable'
}

export type KyselyDatabase = KyselifyDatabase<Database>;

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

export type SubscriptionWithPlan = Stripe.Subscription & {
	plan: Stripe.Plan;
};

export type Workshop = Database['public']['Tables']['club_activities']['Row'] & {
	user_interest: { user_id: string }[];
	interest_count: { interest_count: number | null }[];
	user_registrations: {
		member_user_id: number | null;
		status: Database['public']['Enums']['registration_status'];
	}[];
};

export type WorkshopCalendarEvent = {
	id: string;
	title: string;
	start: string;
	end: string;
	workshop: Workshop;
	isInterested: boolean;
	isLoading: boolean;
	userId: string;
	handleEdit?: (workshop: Workshop) => void;
};
