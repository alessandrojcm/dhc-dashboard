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
