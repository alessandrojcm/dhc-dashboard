<script lang="ts">
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import type { Database } from '$database';
	import dayjs from 'dayjs';
	import Dinero from 'dinero.js';

	type ClubActivity = Database['public']['Tables']['club_activities']['Row'];

	interface Props {
		workshops: ClubActivity[];
		onEdit: (workshop: ClubActivity) => void;
		onDelete: (workshop: ClubActivity) => void;
		onPublish: (workshop: ClubActivity) => void;
		onCancel: (workshop: ClubActivity) => void;
	}

	let { workshops, onEdit, onDelete, onPublish, onCancel }: Props = $props();

	function getStatusColor(status: string) {
		switch (status) {
			case 'planned': return 'bg-yellow-500';
			case 'published': return 'bg-green-500';
			case 'finished': return 'bg-blue-500';
			case 'cancelled': return 'bg-red-500';
			default: return 'bg-gray-500';
		}
	}

	function formatDateTime(dateString: string) {
		return dayjs(dateString).format('MMM D, YYYY h:mm A');
	}

	function formatPrice(price: number) {
		return Dinero({ amount: price, currency: 'EUR' }).toFormat();
	}
</script>

<div class="space-y-4">
	{#if workshops.length === 0}
		<Card>
			<CardContent class="pt-6">
				<div class="text-center text-muted-foreground">
					No workshops found. Create your first workshop to get started.
				</div>
			</CardContent>
		</Card>
	{:else}
		{#each workshops as workshop}
			<Card>
				<CardHeader>
					<div class="flex justify-between items-start">
						<CardTitle>{workshop.title}</CardTitle>
						<Badge class={getStatusColor(workshop.status)}>
							{workshop.status}
						</Badge>
					</div>
				</CardHeader>
				<CardContent>
					<div class="space-y-2">
						{#if workshop.description}
							<p class="text-sm text-muted-foreground">{workshop.description}</p>
						{/if}
						<div class="grid grid-cols-2 gap-4 text-sm">
							<div>
								<strong>Start:</strong> {formatDateTime(workshop.start_date)}
							</div>
							<div>
								<strong>End:</strong> {formatDateTime(workshop.end_date)}
							</div>
							<div>
								<strong>Location:</strong> {workshop.location}
							</div>
							<div>
								<strong>Capacity:</strong> {workshop.max_capacity}
							</div>
							<div>
								<strong>Member Price:</strong> {formatPrice(workshop.price_member)}
							</div>
							<div>
								<strong>Non-Member Price:</strong> {formatPrice(workshop.price_non_member)}
							</div>
						</div>
						<div class="flex gap-2 mt-4">
							<Button variant="outline" size="sm" onclick={() => onEdit(workshop)}>
								Edit
							</Button>
							
							{#if workshop.status === 'planned'}
								<Button variant="default" size="sm" onclick={() => onPublish(workshop)}>
									Publish
								</Button>
							{/if}
							
							{#if workshop.status === 'planned' || workshop.status === 'published'}
								<Button variant="destructive" size="sm" onclick={() => onCancel(workshop)}>
									Cancel
								</Button>
							{/if}
							
							{#if workshop.status === 'planned'}
								<Button variant="destructive" size="sm" onclick={() => onDelete(workshop)}>
									Delete
								</Button>
							{/if}
						</div>
					</div>
				</CardContent>
			</Card>
		{/each}
	{/if}
</div>
