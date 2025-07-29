<script lang="ts">
	import WorkshopForm from '$lib/components/workshop-form.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import { goto } from '$app/navigation';
	import { Sparkles } from 'lucide-svelte';

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

	{#if data.isGenerated}
		<Alert variant="default" class="border-blue-200 bg-blue-50">
			<Sparkles class="h-4 w-4 text-blue-600" />
			<AlertDescription class="text-blue-800">
				Workshop details have been generated from your description. Review and modify as needed before creating.
			</AlertDescription>
		</Alert>
	{/if}

	<WorkshopForm {data} mode="create" onSuccess={handleSuccess} />
</div>
