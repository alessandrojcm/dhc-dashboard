<!--
	ALE-392: one person's Invite button, on the console's attended list and the
	Invitable view. One click sends the standard Invitation; a refusal is
	Phoenix's named reason, shown under the button on the row.
-->
<script lang="ts">
import { toast } from "svelte-sonner";
import { Button } from "#lib/components/ui/button/index.js";
import { inviteAttendee } from "./invitations.remote";

let {
	workshopId,
	intakeId,
	name,
}: { workshopId: string; intakeId: string; name: string } = $props();

const invite = $derived(inviteAttendee.for(intakeId));
const refusal = $derived(
	invite.result && !invite.result.ok ? invite.result.error : null,
);
</script>

<form
	class="flex flex-col items-end gap-1"
	{...invite.enhance(async (instance) => {
		if (!(await instance.submit())) return;
		if (instance.result?.ok) toast.success(`Invitation sent to ${name}`);
	})}
>
	<input {...invite.fields.id.as("hidden", workshopId)} />
	<input {...invite.fields.intakeId.as("hidden", intakeId)} />
	<Button type="submit" size="sm" disabled={!!invite.pending}>Invite</Button>
	{#if refusal}<span
			class="text-xs text-destructive"
			data-testid="invite-refusal">{refusal}</span
		>{/if}
</form>
