<script lang="ts">
	import { createQuery, createMutation, useQueryClient } from '@tanstack/svelte-query';
	import WorkshopCalendar from '$lib/components/workshops/workshop-calendar.svelte';
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import { toast } from 'svelte-sonner';
	import { CalendarDays } from 'lucide-svelte';

	let { data } = $props();
	let supabase = data.supabase;
	const userId = data!.user!.id;

	const queryClient = useQueryClient();

	const workshopsQuery = createQuery(() => ({
		queryKey: ['workshops', 'planned'],
		queryFn: async ({ signal }) => {
			const { data: workshops, error } = await supabase
				.from('club_activities')
				.select(`
					*,
					interest_count:club_activity_interest_counts(interest_count),
					user_interest:club_activity_interest(user_id)
				`)
				.abortSignal(signal)
				.eq('status', 'planned')
				.order('start_date', { ascending: true });

			if (error) throw error;
			return workshops;
		}
	}));

	// Express/withdraw interest mutation (using thunk pattern)
	const interestMutation = createMutation(() => ({
		mutationFn: async (workshopId: string) => {
			const response = await fetch(`/api/workshops/${workshopId}/interest`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' }
			});

			if (!response.ok) {
				const error = await response.json();
				throw new Error(error.message || 'Failed to manage interest');
			}

			return response.json();
		},
		onSuccess: (data) => {
			queryClient.invalidateQueries({ queryKey: ['workshops', 'planned'] });
			toast.success(data.message);
		},
		onError: (error) => {
			toast.error(error.message);
		}
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

	{#if workshopsQuery.isLoading}
		<div class="space-y-4">
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
		<div class="grid gap-6">
			<!-- Calendar View -->
			<Card>
				<CardHeader>
					<CardTitle>Workshop Calendar</CardTitle>
					<CardDescription>View planned workshops and express your interest</CardDescription>
				</CardHeader>
				<CardContent>
					<WorkshopCalendar
						workshops={workshopsQuery.data ?? []}
						onInterestToggle={handleInterestToggle}
						{userId}
						isLoading={interestMutation.isPending}
					/>
				</CardContent>
			</Card>
		</div>
	{/if}
</div>
