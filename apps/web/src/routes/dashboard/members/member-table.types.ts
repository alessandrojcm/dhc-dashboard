export type MemberStatus = "active" | "inactive" | "paused";

export type SocialMediaConsent =
	| "no"
	| "yes_recognizable"
	| "yes_unrecognizable";

export type MemberTableRow = {
	id: string;
	first_name: string;
	last_name: string;
	email: string;
	phone_number: string | null;
	gender: string | null;
	pronouns: string | null;
	is_active: boolean;
	preferred_weapon: string[];
	membership_start_date: string | null;
	membership_end_date: string | null;
	last_payment_date: string | null;
	insurance_form_submitted: boolean;
	age: number | null;
	social_media_consent: SocialMediaConsent;
	next_of_kin_name: string | null;
	next_of_kin_phone: string | null;
	guardian_first_name: string | null;
	guardian_last_name: string | null;
	guardian_phone_number: string | null;
	medical_conditions: string | null;
	subscription_paused_until: string | null;
	membership_status: MemberStatus;
};
