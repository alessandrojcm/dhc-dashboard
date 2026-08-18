<script lang="ts">
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { Button, buttonVariants } from "$lib/components/ui/button";
import { Textarea } from "$lib/components/ui/textarea";
import {
	Popover,
	PopoverContent,
	PopoverTrigger,
} from "$lib/components/ui/popover";
import { createMutation } from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import { Sparkles, LoaderCircle } from "@lucide/svelte";
import { generateWorkshop } from "../../../routes/dashboard/my-workshops/generate.remote";

let prompt = $state("");
let open = $state(false);

const generateWorkshopMutation = createMutation(() => ({
	mutationFn: async (promptText: string) => {
		return generateWorkshop({ prompt: promptText });
	},
	onSuccess: (data) => {
		if (data.success === false) {
			toast.error(data.error || "Failed to generate workshop");
			return;
		}

		const encodedData = encodeURIComponent(JSON.stringify(data.data));

		open = false;
		prompt = "";
		goto(resolve(`/dashboard/workshops/create?generated=${encodedData}`));
	},
	onError: (error) => {
		toast.error(
			error instanceof Error ? error.message : "Failed to generate workshop",
		);
	},
}));

function handleSubmit() {
	if (!prompt.trim()) {
		toast.error("Please enter a workshop description");
		return;
	}
	generateWorkshopMutation.mutate(prompt.trim());
}

function handleKeydown(event: KeyboardEvent) {
	if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
		event.preventDefault();
		handleSubmit();
	}
}
</script>

<Popover bind:open>
	<PopoverTrigger
		class={`${buttonVariants({ variant: "outline" })} w-full sm:w-auto`}
	>
		<Sparkles aria-hidden="true" class="h-4 w-4" />
		Quick create
	</PopoverTrigger>
	<PopoverContent
		class="w-[calc(100vw-2rem)] max-w-96 p-4"
		align="end"
		sideOffset={8}
	>
		<div class="space-y-4">
			<div class="space-y-2">
				<h4 class="font-bold leading-none">Quick create a workshop</h4>
				<p id="quick-create-help" class="text-sm text-muted-foreground">
					Describe your workshop in natural language and we'll generate the
					details for you.
				</p>
			</div>

			<div class="space-y-3">
				<label for="quick-create-description" class="text-sm font-medium">
					Workshop description
				</label>
				<Textarea
					id="quick-create-description"
					bind:value={prompt}
					placeholder="e.g., Create a longsword workshop next Saturday from 2pm to 4pm, cost is 25 euro, maximum 15 people"
					class="min-h-[100px] resize-none"
					onkeydown={handleKeydown}
					disabled={generateWorkshopMutation.isPending}
					aria-describedby="quick-create-help quick-create-shortcut"
				/>

				<div
					class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
				>
					<p id="quick-create-shortcut" class="text-xs text-muted-foreground">
						Press Cmd+Enter (or Ctrl+Enter) to generate
					</p>
					<div class="grid grid-cols-2 gap-2 sm:flex">
						<Button
							variant="outline"
							onclick={() => {
								open = false;
								prompt = "";
							}}
							disabled={generateWorkshopMutation.isPending}
						>
							Cancel
						</Button>
						<Button
							onclick={handleSubmit}
							disabled={!prompt.trim() || generateWorkshopMutation.isPending}
							class="gap-2"
						>
							{#if generateWorkshopMutation.isPending}
								<LoaderCircle aria-hidden="true" class="h-3 w-3 animate-spin" />
								Generating...
							{:else}
								<Sparkles aria-hidden="true" class="h-3 w-3" />
								Generate
							{/if}
						</Button>
					</div>
				</div>
			</div>
		</div>
	</PopoverContent>
</Popover>
