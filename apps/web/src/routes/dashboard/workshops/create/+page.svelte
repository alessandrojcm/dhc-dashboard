<script lang="ts">
import WorkshopForm from "$lib/components/workshop-form.svelte";
import { Button } from "$lib/components/ui/button";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { ArrowLeft, Sparkles } from "@lucide/svelte";

const { data } = $props();

function handleSuccess() {
	setTimeout(() => goto(resolve("/dashboard/workshops")), 2000);
}
</script>

<svelte:head>
	<title>Create workshop | Dublin HEMA Club</title>
</svelte:head>

<div class="mx-auto max-w-7xl space-y-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-10">
	<header
		class="flex flex-col gap-5 border-b border-border/80 pb-6 sm:flex-row sm:items-end sm:justify-between"
	>
		<div class="max-w-2xl space-y-2">
			<p class="text-xs font-bold tracking-[0.18em] text-primary uppercase">
				Workshop planning
			</p>
			<h1 class="text-3xl font-bold tracking-tight sm:text-4xl">
				Create a workshop
			</h1>
			<p class="text-base leading-7 text-muted-foreground">
				Add the essentials, choose who can attend, and decide how members should
				hear about it.
			</p>
		</div>

		<Button variant="outline" href="/dashboard/workshops">
			<ArrowLeft aria-hidden="true" />
			All workshops
		</Button>
	</header>

	{#if data.isGenerated}
		<Alert variant="default" class="border-secondary/60 bg-secondary/10">
			<Sparkles aria-hidden="true" class="h-4 w-4 text-primary" />
			<AlertDescription class="text-foreground">
				<strong>Draft generated.</strong> Review the suggested details and make any
				changes before creating the workshop.
			</AlertDescription>
		</Alert>
	{/if}

	<WorkshopForm
		mode="create"
		initialData={data.initialData}
		onSuccess={handleSuccess}
	/>
</div>
