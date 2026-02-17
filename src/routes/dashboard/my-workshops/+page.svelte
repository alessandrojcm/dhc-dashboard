<script lang="ts">
import {
	createQuery,
	createMutation,
	useQueryClient,
} from "@tanstack/svelte-query";
import WorkshopList from "$lib/components/workshops/workshop-list.svelte";
import {
	Card,
	CardContent,
	CardDescription,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Skeleton } from "$lib/components/ui/skeleton";
import {
	Tabs,
	TabsContent,
	TabsList,
	TabsTrigger,
} from "$lib/components/ui/tabs/index.js";
import { toast } from "svelte-sonner";
import { CalendarDays } from "lucide-svelte";
import type { ClubActivityWithInterest } from "$lib/types";

let { data } = $props();
let supabase = data.supabase;
const userId = data.user!.id;

const queryClient = useQueryClient();
let activeTab = $state("published");

const workshopsQuery = createQuery(() => ({
	queryKey: ["workshops", "planned"],
	queryFn: async ({ signal }) => {
		const { data: workshops, error } = await supabase
			.from("club_activities")
			.select(
				`
					*,
					interest_count:club_activity_interest_counts(interest_count),
					user_interest:club_activity_interest(user_id)
				`,
			)
			.abortSignal(signal)
			.eq("status", "planned")
			.order("start_date", { ascending: true });

		if (error) throw error;
		return workshops as ClubActivityWithInterest[];
	},
}));

const publishedWorkshopsQuery = createQuery(() => ({
	queryKey: ["workshops", "published"],
	queryFn: async ({ signal }) => {
		const { data: workshops, error } = await supabase
			.from("club_activities")
			.select(
				`
					*,
					attendee_count:club_activity_registrations(id, member_user_id, status)
				`,
			)
			.abortSignal(signal)
			.eq("status", "published")
			.order("start_date", { ascending: true });

		if (error) throw error;
		return workshops as ClubActivityWithInterest[];
	},
}));

// Express/withdraw interest mutation (using thunk pattern)
const interestMutation = createMutation(() => ({
	mutationFn: async (workshopId: string) => {
		const response = await fetch(`/api/workshops/${workshopId}/interest`, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
		});

		if (!response.ok) {
			const error = (await response.json()) as { message?: string };
			throw new Error(error.message || "Failed to manage interest");
		}

		return response.json() as Promise<{ message: string }>;
	},
	onSuccess: (data: { message: string }) => {
		queryClient.invalidateQueries({ queryKey: ["workshops", "planned"] });
		toast.success(data.message);
	},
	onError: (error) => {
		toast.error(error.message);
	},
}));

const handleInterestToggle = (workshopId: string) => {
	interestMutation.mutate(workshopId);
};
</script>

<div class="container mx-auto p-6 space-y-6">
	<div class="flex items-center gap-2">
		<CalendarDays class="w-6 h-6" />
		<h1 class="text-2xl font-bold">My Workshops</h1>
	</div>

	<Tabs bind:value={activeTab}>
		<TabsList>
			<TabsTrigger value="published">Upcoming</TabsTrigger>
			<TabsTrigger value="planned">Planned</TabsTrigger>
		</TabsList>

		<TabsContent value="published">
			{#if publishedWorkshopsQuery.isLoading}
				<div class="space-y-4">
					<!-- eslint-disable-next-line @typescript-eslint/no-unused-vars -->
					{#each Array(3) as _, index (index)}
						<Skeleton class="h-32 w-full" />
					{/each}
				</div>
			{:else if publishedWorkshopsQuery.error}
				<Card>
					<CardContent class="pt-6">
						<p class="text-destructive">
							Error loading workshops: {publishedWorkshopsQuery.error.message}
						</p>
					</CardContent>
				</Card>
			{:else}
				<Card>
					<CardHeader>
						<CardTitle>Upcoming Workshops</CardTitle>
						<CardDescription>View upcoming workshops and sign up for them</CardDescription>
					</CardHeader>
					<CardContent>
						<WorkshopList
							{userId}
							workshops={publishedWorkshopsQuery.data ?? []}
							onInterestToggle={handleInterestToggle}
							isLoading={interestMutation.isPending}
						/>
					</CardContent>
				</Card>
			{/if}
		</TabsContent>

		<TabsContent value="planned">
			{#if workshopsQuery.isLoading}
				<div class="space-y-4">
					<!-- eslint-disable-next-line @typescript-eslint/no-unused-vars -->
					{#each Array(3) as _, index (index)}
						<Skeleton class="h-32 w-full" />
					{/each}
				</div>
			{:else if workshopsQuery.error}
				<Card>
					<CardContent class="pt-6">
						<p class="text-destructive">Error loading workshops: {workshopsQuery.error.message}</p>
					</CardContent>
				</Card>
			{:else}
				<Card>
					<CardHeader>
						<CardTitle>Planned Workshops</CardTitle>
						<CardDescription>View planned workshops and express your interest</CardDescription>
					</CardHeader>
					<CardContent>
						<WorkshopList
							{userId}
							workshops={workshopsQuery.data ?? []}
							onInterestToggle={handleInterestToggle}
							isLoading={interestMutation.isPending}
						/>
					</CardContent>
				</Card>
			{/if}
		</TabsContent>
	</Tabs>
</div>
