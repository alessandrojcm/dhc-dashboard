<script lang="ts">
	import dayjs from 'dayjs';
	import type { WorkshopCalendarEvent } from '$lib/types';

	let { calendarEvent }: {
		calendarEvent: WorkshopCalendarEvent;
	} = $props();
	const startTime = $derived(dayjs(calendarEvent.start).format('HH:MM'));
	const isInterested = $derived(calendarEvent.workshop.user_interest.map(i => i.user_id).includes(calendarEvent.userId));
</script>

<div
	class="p-1 cursor-pointer h-full bg-primary text-white data-[is-interested='true']:bg-primary-foreground data-[is-interested='true']:text-black data-is-interested:border"
	data-is-interested={isInterested}>
	{startTime}
	{calendarEvent.title}
</div>
