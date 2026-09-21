<!-- PROTOTYPE — throwaway. Occurrence inspector dialog (from Variant A), shared with Variant D. -->
<script lang="ts">
import { Button } from "$lib/components/ui/button";
import * as Dialog from "$lib/components/ui/dialog";
import dayjs from "dayjs";
import { CalendarOff, Check, ExternalLink, Pencil } from "@lucide/svelte";
import DiscordPreview from "./discord-preview.svelte";
import {
	CHANNEL,
	DELIVERY_LABEL,
	KIND_LABEL,
	STATUS_LABEL,
	decisionLabel,
	formatLongDate,
	formatRange,
	statusOf,
	store,
	type Occurrence,
	type Training,
} from "./training-prototype-store.svelte";

let {
	open = $bindable(false),
	occurrence,
	onSkip,
	onOverride,
	onEditTraining,
}: {
	open: boolean;
	occurrence: Occurrence | null;
	onSkip: (o: Occurrence) => void;
	onOverride: (o: Occurrence) => void;
	onEditTraining: (t: Training) => void;
} = $props();

const PRECEDENCE = [
	{
		id: "bank_holiday",
		label: "Irish bank holiday",
		note: "Cannot be overridden",
	},
	{ id: "disabled", label: "Training disabled" },
	{ id: "suppressed", label: "Training Suppression" },
	{ id: "overridden", label: "Training Override" },
	{ id: "default", label: "Training defaults" },
] as const;

function precedenceState(
	o: Occurrence,
	step: (typeof PRECEDENCE)[number]["id"],
) {
	const order = PRECEDENCE.map((p) => p.id);
	const winner = order.indexOf(o.decision);
	const index = order.indexOf(step);
	if (index === winner) return "won";
	if (index < winner) return "passed";
	// A later rule that would have applied had the winner not.
	if (step === "overridden" && o.override) return "shadowed";
	if (step === "suppressed" && o.suppression) return "shadowed";
	return "unreached";
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content
		class="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-3xl"
	>
		{#if occurrence}
			{@const status = statusOf(occurrence)}
			<Dialog.Header>
				<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
					{KIND_LABEL[occurrence.training.kind]} · {formatLongDate(
						occurrence.date,
					)} · {occurrence.startTime} · {CHANNEL[occurrence.training.kind]}
				</p>
				<Dialog.Title class="flex flex-wrap items-center gap-2 text-2xl">
					{occurrence.title}
					<span class="tr-pill tr-pill--{status}"
						>{STATUS_LABEL[status] ?? status}</span
					>
				</Dialog.Title>
				<Dialog.Description>
					{#if occurrence.past && occurrence.delivery}
						{DELIVERY_LABEL[occurrence.delivery.state]}
						{#if occurrence.delivery.at}at {dayjs(
								occurrence.delivery.at,
							).format("HH:mm:ss")}{/if}
						{#if occurrence.delivery.reason}
							— {occurrence.delivery.reason}{/if}
					{:else if occurrence.willPost}
						Will post at {occurrence.startTime} Europe/Dublin. Snapshot freezes at
						that moment; edits after it affect later dates only.
					{:else}
						Nothing will post on this date — {decisionLabel(
							occurrence.decision,
							occurrence.holiday,
						).toLowerCase()}.
					{/if}
				</Dialog.Description>
			</Dialog.Header>

			<div class="grid gap-5 md:grid-cols-[minmax(0,15rem)_minmax(0,1fr)]">
				<div>
					<p
						class="mb-2 text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
					>
						Why this outcome
					</p>
					<ol class="space-y-1">
						{#each PRECEDENCE as step (step.id)}
							{@const state = precedenceState(occurrence, step.id)}
							<li class="tr-rule tr-rule--{state}">
								<span class="tr-rule-mark" aria-hidden="true">
									{#if state === "won"}<Check
											class="size-3.5"
										/>{:else if state === "passed"}—{:else}·{/if}
								</span>
								<span class="min-w-0">
									<span class="block text-sm font-semibold">{step.label}</span>
									{#if state === "won" && step.id === "suppressed" && occurrence.suppression}
										<span class="block text-xs text-muted-foreground"
											>{formatRange(
												occurrence.suppression.from,
												occurrence.suppression.to,
											)}{occurrence.suppression.note
												? ` · ${occurrence.suppression.note}`
												: ""}</span
										>
									{:else if (state === "won" || state === "shadowed") && step.id === "overridden" && occurrence.override}
										<span class="block text-xs text-muted-foreground"
											>{formatRange(
												occurrence.override.from,
												occurrence.override.to,
											)}{state === "shadowed"
												? " · stored, not applied"
												: ""}</span
										>
									{:else if state === "won" && step.id === "bank_holiday" && occurrence.holiday}
										<span class="block text-xs text-muted-foreground"
											>{occurrence.holiday.name}{"note" in step
												? ` · ${step.note}`
												: ""}</span
										>
									{/if}
								</span>
							</li>
						{/each}
					</ol>
				</div>
				<div class="space-y-3">
					<p
						class="text-xs font-bold tracking-[0.14em] text-muted-foreground uppercase"
					>
						{occurrence.past ? "What was posted" : "What will post"}
					</p>
					<DiscordPreview
						channel={CHANNEL[occurrence.training.kind]}
						rendered={occurrence.rendered}
						threadName={occurrence.threadName}
						muted={!occurrence.willPost}
					/>
					{#if occurrence.past && occurrence.delivery && occurrence.delivery.messageId}
						<dl class="grid grid-cols-2 gap-2 text-xs">
							<div class="rounded-lg border px-3 py-2">
								<dt class="text-muted-foreground">Message id</dt>
								<dd class="font-mono">{occurrence.delivery.messageId}</dd>
							</div>
							<div class="rounded-lg border px-3 py-2">
								<dt class="text-muted-foreground">Thread id</dt>
								<dd class="font-mono">
									{occurrence.delivery.threadId ?? "— none"}
								</dd>
							</div>
						</dl>
					{/if}
				</div>
			</div>

			<Dialog.Footer class="flex-wrap gap-2 sm:justify-between">
				<div class="flex flex-wrap gap-2">
					{#if !occurrence.past && occurrence.decision !== "bank_holiday"}
						{#if occurrence.suppression}
							<Button
								variant="outline"
								onclick={() => store.unsuppress(occurrence.suppression!.id)}
							>
								<CalendarOff aria-hidden="true" /> Remove suppression
							</Button>
						{:else if occurrence.decision !== "disabled"}
							<Button variant="outline" onclick={() => onSkip(occurrence)}>
								<CalendarOff aria-hidden="true" /> Skip this date
							</Button>
						{/if}
						{#if occurrence.override}
							<Button
								variant="outline"
								onclick={() => store.removeOverride(occurrence.override!.id)}
							>
								Remove override
							</Button>
						{:else}
							<Button variant="outline" onclick={() => onOverride(occurrence)}>
								<Pencil aria-hidden="true" /> Change copy for this date
							</Button>
						{/if}
					{/if}
					{#if occurrence.past && occurrence.delivery?.messageId}
						<Button variant="ghost" class="text-muted-foreground"
							><ExternalLink aria-hidden="true" /> Open in Discord</Button
						>
					{/if}
				</div>
				<Button
					variant="ghost"
					onclick={() => onEditTraining(occurrence.training)}
					>Edit Training defaults</Button
				>
			</Dialog.Footer>
		{/if}
	</Dialog.Content>
</Dialog.Root>

<style>
.tr-rule {
	display: flex;
	gap: 0.6rem;
	align-items: flex-start;
	border-radius: 0.6rem;
	padding: 0.45rem 0.6rem;
	color: hsl(var(--muted-foreground));
}

.tr-rule-mark {
	display: inline-flex;
	width: 1.25rem;
	height: 1.25rem;
	flex: none;
	align-items: center;
	justify-content: center;
	border-radius: 9999px;
	border: 1px solid hsl(var(--border));
	font-size: 0.75rem;
}

.tr-rule--won {
	color: hsl(var(--foreground));
	background: hsl(var(--primary) / 0.08);
}

.tr-rule--won .tr-rule-mark {
	border-color: hsl(var(--primary));
	background: hsl(var(--primary));
	color: hsl(var(--primary-foreground));
}

.tr-rule--shadowed {
	text-decoration: line-through;
}

.tr-rule--unreached {
	opacity: 0.55;
}
</style>
