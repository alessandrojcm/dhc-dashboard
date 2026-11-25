<!--
	ALE-392: one person's Invite button, on the console's attended list and the
	Invitable view. One click sends the standard Invitation; a refusal is
	Phoenix's named reason, shown under the button on the row.
-->
<script lang="ts">
import { toast } from "svelte-sonner";
import { LoaderCircle, MailPlus } from "@lucide/svelte";
import { Button } from "#lib/components/ui/button/index.js";
import { inviteAttendee } from "./invitations.remote";

let {
	workshopId,
	intakeId,
	name,
	compact = false,
}: {
	workshopId: string;
	intakeId: string;
	name: string;
	// Badge-height, for a row action that must not change the row's height.
	compact?: boolean;
} = $props();

const invite = $derived(inviteAttendee.for(intakeId));
const refusal = $derived(
	invite.result && !invite.result.ok ? invite.result.error : null,
);
</script>

<form
	class="flex flex-col items-end gap-2"
	aria-label={`Invite ${name}`}
	aria-busy={!!invite.pending}
	{...invite.enhance(async (instance) => {
		if (!(await instance.submit())) return;
		if (instance.result?.ok) toast.success(`Invitation sent to ${name}`);
	})}
>
	<input {...invite.fields.id.as("hidden", workshopId)} />
	<input {...invite.fields.intakeId.as("hidden", intakeId)} />
	<Button
		type="submit"
		variant={compact ? "outline" : "default"}
		class={compact
			? "h-7 gap-1.5 rounded-md px-2.5 text-xs shadow-none has-[>svg]:px-2.5 [&_svg]:size-3.5"
			: "min-w-28"}
		disabled={!!invite.pending}
	>
		{#if invite.pending}<LoaderCircle
				class="size-4 animate-spin motion-reduce:animate-none"
				aria-hidden="true"
			/>Sending…{:else}<MailPlus class="size-4" aria-hidden="true" />Invite{/if}
	</Button>
	{#if refusal}<span
			class="max-w-xs text-sm text-destructive"
			role="alert"
			data-testid="invite-refusal">{refusal}</span
		>{/if}
</form>
