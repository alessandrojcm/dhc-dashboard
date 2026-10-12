<!--
	ALE-379: the Staff dialog for one scheduled workshop. Saving replaces the
	whole Staff list; access follows at once and the people added or removed
	get an in-app Notification. No attendee is emailed.
-->
<script lang="ts">
import type {
	BeginnersWorkshop,
	BeginnersWorkshopStaffCandidate,
} from "@dhc/api-client";
import { toast } from "svelte-sonner";
import { formatCivilDate } from "#lib/club-calendar.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import WorkshopDialog from "#lib/components/beginners-workshops/workshop-dialog.svelte";
import { workshopStaffSchema } from "#lib/schemas/beginnersWorkshop.js";
import StaffPickers from "./staff-pickers.svelte";
import { setWorkshopStaff } from "./workshops.remote";

let {
	workshop,
	candidates,
	open = $bindable(false),
}: {
	workshop: BeginnersWorkshop;
	candidates: BeginnersWorkshopStaffCandidate[];
	open?: boolean;
} = $props();

const form = $derived(setWorkshopStaff.for(workshop.id));
// The dialog is keyed by workshop, so its picks start from that workshop.
// svelte-ignore state_referenced_locally
let coach = $state(workshop.staff.coach?.principalId ?? "");
// svelte-ignore state_referenced_locally
let assistants = $state(
	workshop.staff.assistants.map((assistant) => assistant.principalId),
);
let formError = $state<string | null>(null);
</script>

<Dialog.Root bind:open>
	<WorkshopDialog>
		<Dialog.Header>
			<Dialog.Title>Staff for {formatCivilDate(workshop.date)}</Dialog.Title>
			<Dialog.Description>
				Assigned staff can access this workshop’s check-in screen immediately.
				Attendees are not emailed about staff changes.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(workshopStaffSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success("Staff saved");
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-5"
			aria-label="Workshop Staff"
		>
			<input {...form.fields.id.as("hidden", workshop.id)} />
			{#if coach}
				<input {...form.fields.coachPrincipalId.as("hidden", coach)} />
			{/if}
			{#each assistants as assistant, index (assistant)}
				<input
					{...form.fields.assistantPrincipalIds[index].as("hidden", assistant)}
				/>
			{/each}

			<StaffPickers
				idPrefix={`staff-${workshop.id}`}
				{candidates}
				current={workshop.staff}
				bind:coach
				bind:assistants
				coachIssues={form.fields.coachPrincipalId.issues() ?? []}
				assistantIssues={form.fields.assistantPrincipalIds.issues() ?? []}
			/>

			{#if formError}
				<p class="text-sm text-destructive" role="alert">{formError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Cancel</Button
				>
				<Button type="submit" disabled={!!form.pending}
					>{form.pending ? "Saving…" : "Save Staff"}</Button
				>
			</Dialog.Footer>
		</form>
	</WorkshopDialog>
</Dialog.Root>
