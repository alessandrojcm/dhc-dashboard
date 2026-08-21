<script lang="ts">
import WorkshopForm from "$lib/components/workshop-form.svelte";
import { Button } from "$lib/components/ui/button";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";

const { data } = $props();

function handleSuccess() {
	setTimeout(() => goto(resolve("/dashboard/workshops")), 2000);
}
</script>

<div class="mx-auto max-w-7xl space-y-8 px-4 py-6 sm:px-6 lg:px-8 lg:py-10">
	<div class="flex items-center justify-between">
		<h1 class="text-3xl font-bold">Edit Workshop</h1>
		<Button variant="outline" href="/dashboard/workshops"
			>Back to Workshops</Button
		>
	</div>

	<WorkshopForm
		mode="edit"
		initialData={data.initialData}
		onSuccess={handleSuccess}
		priceEditingDisabled={data.priceEditingDisabled}
		workshopStatus={data.workshop.status}
		workshopEditable={data.workshopEditable}
	/>
</div>
