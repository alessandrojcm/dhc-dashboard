<script lang="ts">
	import { createMutation } from '@tanstack/svelte-query';
	import { Button } from '$lib/components/ui/button';
	import { Badge } from '$lib/components/ui/badge';
	import * as Select from '$lib/components/ui/select';
	import { Textarea } from '$lib/components/ui/textarea';
	import { toast } from 'svelte-sonner';

	interface Props {
		attendees: any[];
		workshopId: string;
		onAttendanceUpdated?: () => void;
	}

	let { attendees, workshopId, onAttendanceUpdated }: Props = $props();

	let attendanceUpdates = $state<Record<string, {
		attendance_status: string;
		notes: string;
	}>>(
		attendees.reduce((acc, attendee) => {
			acc[attendee.id] = {
				attendance_status: attendee.attendance_status || 'pending',
				notes: attendee.attendance_notes || ''
			};
			return acc;
		}, {} as Record<string, { attendance_status: string; notes: string }>)
	);

	const hasUpdates: boolean = $derived.by(() => {
		return attendees.some(attendee => {
			const update = attendanceUpdates[attendee.id];
			return update && (
				update.attendance_status !== (attendee.attendance_status || 'pending') ||
				update.notes !== (attendee.attendance_notes || '')
			);
		});
	});

	const updateAttendanceMutation = createMutation(() => ({
		mutationFn: async (updates: any[]) => {
			const response = await fetch(`/api/workshops/${workshopId}/attendance`, {
				method: 'PUT',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ attendance_updates: updates })
			});

			if (!response.ok) {
				const error = await response.json();
				throw new Error(error.error || 'Failed to update attendance');
			}

			return response.json();
		},
		onSuccess: () => {
			// Reset attendance updates to match current attendee data
			attendees.forEach(attendee => {
				if (attendanceUpdates[attendee.id]) {
					attendanceUpdates[attendee.id] = {
						attendance_status: attendee.attendance_status || 'pending',
						notes: attendee.attendance_notes || ''
					};
				}
			});
			onAttendanceUpdated?.();
		},
		onError: (error: any) => {
			toast.error(error.message);
		}
	}));



	function saveAttendance() {
		const updates = attendees
			.filter(attendee => {
				const update = attendanceUpdates[attendee.id];
				return update && (
					update.attendance_status !== (attendee.attendance_status || 'pending') ||
					update.notes !== (attendee.attendance_notes || '')
				);
			})
			.map(attendee => ({
				registration_id: attendee.id,
				attendance_status: attendanceUpdates[attendee.id].attendance_status,
				notes: attendanceUpdates[attendee.id].notes
			}));

		if (updates.length === 0) {
			toast.error('No changes to save');
			return;
		}

		updateAttendanceMutation.mutate(updates);
	}

	function getStatusBadgeVariant(status: string) {
		switch (status) {
			case 'attended': return 'default';
			case 'no_show': return 'destructive';
			case 'excused': return 'secondary';
			default: return 'outline';
		}
	}

	function getAttendeeDisplayName(attendee: any) {
		return attendee.user_profiles?.first_name 
			? `${attendee.user_profiles.first_name} ${attendee.user_profiles.last_name}`
			: `${attendee.external_users?.first_name} ${attendee.external_users?.last_name}`;
	}
</script>

<div class="space-y-4">
	{#each attendees as attendee (attendee.id)}
		<div class="flex items-center justify-between p-4 border rounded-lg">
			<div class="flex-1">
				<div class="font-medium">{getAttendeeDisplayName(attendee)}</div>
				<div class="text-sm text-muted-foreground">
					{attendee.user_profiles?.email || attendee.external_users?.email}
				</div>
				<Badge variant={getStatusBadgeVariant(attendee.attendance_status)} class="mt-1">
					{attendee.attendance_status || 'pending'}
				</Badge>
			</div>
			
			<div class="flex items-center gap-4">
				<Select.Root 
					type="single"
					bind:value={attendanceUpdates[attendee.id].attendance_status}
				>
					<Select.Trigger class="w-32">
						{attendanceUpdates[attendee.id].attendance_status}
					</Select.Trigger>
					<Select.Content>
						<Select.Item value="pending">Pending</Select.Item>
						<Select.Item value="attended">Attended</Select.Item>
						<Select.Item value="no_show">No Show</Select.Item>
						<Select.Item value="excused">Excused</Select.Item>
					</Select.Content>
				</Select.Root>
				
				<Textarea
					placeholder="Notes..."
					class="w-48 h-8"
					bind:value={attendanceUpdates[attendee.id].notes}
				/>
			</div>
		</div>
	{/each}
	
	{#if hasUpdates}
		<div class="flex justify-end pt-4">
			<Button 
				on:click={saveAttendance}
				disabled={updateAttendanceMutation.isPending}
			>
				{#if updateAttendanceMutation.isPending}
					Saving...
				{:else}
					Save Changes
				{/if}
			</Button>
		</div>
	{/if}
</div>
