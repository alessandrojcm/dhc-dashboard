<script lang="ts">
	import WorkshopForm from '$lib/components/workshop-form.svelte';
	import { Button } from '$lib/components/ui/button';
	import { goto } from '$app/navigation';

	const { data } = $props();

	function handleSuccess() {
		setTimeout(() => goto('/dashboard/workshops'), 2000);
	}
</script>

<div class="max-w-4xl mx-auto p-6 space-y-8">
	<div class="flex justify-between items-center">
		<h1 class="text-3xl font-bold">Create Workshop</h1>
		<Button variant="outline" href="/dashboard/workshops">
			Back to Workshops
		</Button>
	</div>

	<WorkshopForm {data} mode="create" onSuccess={handleSuccess} />
</div>
