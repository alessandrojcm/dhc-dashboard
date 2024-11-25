import type { Database } from '$database';

export type UserData = {
	firstName: string;
	lastName: string;
	email: string;
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
	items: NavigationItem[];
	role: Set<string>;
};

export type NavData = {
	navMain: NavigationGroup[];
};

export type FetchAndCountResult<T extends keyof Database['public']['Tables']> = {
	data: Database['public']['Tables'][T]['Row'][];
	count: number;
};

export type MutationPayload<T extends keyof Database['public']['Tables']> =
	Database['public']['Tables'][T]['Update'];
