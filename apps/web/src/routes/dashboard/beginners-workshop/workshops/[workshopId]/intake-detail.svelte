<!--
	ALE-386: one Intake on the workshop console — its state, minor badge,
	medical flag, origin, live hold, refund, the Intake Email log (scheduled
	emails marked), its history and link generation — and the commands
	Phoenix says are valid now (`availableCommands`). The UI never works out
	Intake rules: it shows Phoenix's list, and the boundary decides again
	under the lock, answering a stale command with its named reason. All
	commands are submit buttons of one form, so the optional note goes with
	whichever is pressed. There is no copy-link: a link is only ever resent
	or rotated.
-->
<script lang="ts">
import type { BeginnersWorkshopRosterIntake } from "@dhc/api-client";
import { HeartPulse, Link2 } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import {
	emailLogLine,
	formatDublinInstant,
	historyLine,
	holdLabel,
	intakeCommandDone,
	intakeCommandLabel,
	intakeOrigin,
	intakeStateLabel,
	personName,
	refundLabel,
} from "#lib/beginners-workshops/console.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import { intakeCommandSchema } from "#lib/schemas/beginnersWorkshop.js";
import { runIntakeCommand } from "./console.remote";

let {
	workshopId,
	intake,
}: { workshopId: string; intake: BeginnersWorkshopRosterIntake } = $props();

const form = $derived(runIntakeCommand.for(intake.id));
let formError = $state<string | null>(null);
</script>

<div class="flex flex-col gap-5 text-sm" data-testid="intake-detail">
	<header class="flex flex-col gap-2">
		<h3 class="font-heading text-xl leading-tight">{personName(intake)}</h3>
		<div class="flex flex-wrap gap-1.5">
			<Badge variant="secondary" data-testid="intake-state"
				>{intakeStateLabel(intake.state)}</Badge
			>
			{#if intake.minor}<Badge variant="outline">Minor</Badge>{/if}
			{#if intake.medical}<Badge
					variant="outline"
					class="border-destructive text-destructive"
					data-testid="medical-flag"><HeartPulse /> Medical</Badge
				>{/if}
			<Badge variant="outline">{intakeOrigin(intake)}</Badge>
			{#if refundLabel(intake)}<Badge
					variant="outline"
					data-testid="refund-status">{refundLabel(intake)?.text}</Badge
				>{/if}
		</div>
	</header>

	<dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1">
		<dt class="text-muted-foreground">Contacted</dt>
		<dd>{formatDublinInstant(intake.contactedAt)}</dd>
		{#if intake.state === "contacted"}
			<dt class="text-muted-foreground">Window ends</dt>
			<dd>{formatDublinInstant(intake.windowEndsAt)}</dd>
		{/if}
		{#if intake.checkedInAt}
			<dt class="text-muted-foreground">Checked in</dt>
			<dd>{formatDublinInstant(intake.checkedInAt)}</dd>
		{/if}
		<dt class="text-muted-foreground">Link</dt>
		<dd class="flex items-center gap-1" data-testid="link-generation">
			<Link2 class="size-3" /> generation {intake.linkGeneration}
		</dd>
	</dl>

	{#if holdLabel(intake)}
		<p
			class="rounded-lg border border-sky-600/40 bg-sky-50 p-2.5 text-sky-900"
			data-testid="hold-expiry"
		>
			{holdLabel(intake)}. The seat is held until Stripe ends the checkout.
		</p>
	{/if}

	<section class="flex flex-col gap-2" aria-labelledby="intake-commands">
		<h4
			id="intake-commands"
			class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
		>
			Commands
		</h4>
		{#if intake.availableCommands.length}
			<form
				{...form.preflight(intakeCommandSchema).enhance(async (instance) => {
					formError = null;
					if (!(await instance.submit())) return;
					const result = instance.result;
					if (result?.ok) {
						toast.success(
							intakeCommandDone(result.command, result.data.outcome),
						);
						instance.element.reset();
					} else if (result) {
						formError = result.error;
					}
				})}
				class="flex flex-col gap-3"
				aria-label="Intake commands"
			>
				<input {...form.fields.id.as("hidden", workshopId)} />
				<input {...form.fields.intakeId.as("hidden", intake.id)} />
				<Field.Field>
					{@const props = form.fields.note.as("text")}
					<Field.Label for={`${intake.id}-note`}
						>Note (optional, recorded with the command)</Field.Label
					>
					<Textarea
						{...props}
						id={`${intake.id}-note`}
						rows={2}
						maxlength={500}
						placeholder="e.g. “Replied 9 Oct: can't make that date”"
					/>
					{#each form.fields.note.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<div class="flex flex-wrap gap-2" data-testid="intake-commands">
					{#each intake.availableCommands as command (command)}
						<Button
							{...form.fields.command.as("submit", command)}
							size="sm"
							variant={command === "decline" ? "outline" : "secondary"}
							disabled={!!form.pending}>{intakeCommandLabel(command)}</Button
						>
					{/each}
				</div>
				{#if formError}
					<p class="text-sm text-destructive" role="alert">{formError}</p>
				{/if}
			</form>
		{:else}
			<p class="text-muted-foreground">
				No commands for a {intakeStateLabel(intake.state).toLowerCase()} Intake.
			</p>
		{/if}
	</section>

	<section class="flex flex-col gap-1.5" aria-labelledby="intake-emails">
		<h4
			id="intake-emails"
			class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
		>
			Intake Emails
		</h4>
		<ol class="flex flex-col gap-1" data-testid="email-log">
			{#each intake.emailLog as entry, index (index)}
				{@const line = emailLogLine(entry)}
				<li
					class={[
						"flex items-baseline justify-between gap-3 border-b border-dashed border-border/70 pb-1",
						line.scheduled && "text-muted-foreground italic",
					]}
				>
					<span>{line.label}</span>
					<span class="shrink-0 text-xs text-muted-foreground">{line.when}</span
					>
				</li>
			{:else}
				<li class="text-muted-foreground">Nothing queued.</li>
			{/each}
		</ol>
		<p class="text-[11px] text-muted-foreground">
			Queued, not delivery status.
		</p>
	</section>

	<section class="flex flex-col gap-1.5" aria-labelledby="intake-history">
		<h4
			id="intake-history"
			class="text-xs font-bold tracking-wider text-muted-foreground uppercase"
		>
			History
		</h4>
		<ol class="flex flex-col gap-1.5" data-testid="intake-history">
			{#each intake.history as entry, index (index)}
				<li class="flex flex-col">
					<span>{historyLine(entry)}</span>
					{#if entry.note}<span class="text-xs text-muted-foreground"
							>“{entry.note}”</span
						>{/if}
				</li>
			{:else}
				<li class="text-muted-foreground">No commands run yet.</li>
			{/each}
		</ol>
	</section>
</div>
