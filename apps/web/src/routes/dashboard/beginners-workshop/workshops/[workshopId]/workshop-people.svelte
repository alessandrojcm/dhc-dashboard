<script lang="ts">
import type { BeginnersWorkshopConsole } from "@dhc/api-client";
import {
	carriedFeeLabel,
	holdLabel,
	intakeOrigin,
	intakeStateLabel,
	personName,
	refundLabel,
	rosterGroups,
	standingLabel,
	unconfirmedCarriedFeeText,
	unpaidAfterWindowText,
} from "#lib/beginners-workshops/console.js";
import { formatDublinInstant, formatDublinTime } from "#lib/club-calendar.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import * as Tabs from "#lib/components/ui/tabs/index.js";
import { cn } from "#lib/utils.js";
import InviteButton from "../../invite-button.svelte";

let {
	view,
	canInvite,
	onSelect,
}: {
	view: BeginnersWorkshopConsole;
	canInvite: boolean;
	onSelect: (id: string) => void;
} = $props();

let selected = $state("all");
const groups = $derived(rosterGroups(view));
// Finalisation replaces the live filters. A stale selection falls back to All.
const active = $derived(
	groups.find((group) => group.key === selected) ?? groups[0]!,
);
const unpaid = $derived(
	groups.find((group) => group.key === "awaitingPayment")?.intakes ?? [],
);
const unconfirmed = $derived(
	groups.find((group) => group.key === "awaitingConfirmation")?.intakes ?? [],
);
const overdue = $derived(
	new Set(view.unpaidAfterWindow.map((person) => person.id)),
);
</script>

<section
	class="min-w-0 space-y-4 rounded-2xl border bg-card p-4 sm:p-6"
	aria-label="People"
>
	<h2 class="font-heading text-xl">People</h2>
	<Tabs.Root
		value={active.key}
		onValueChange={(value) => (selected = value)}
		class="gap-4"
	>
		<Tabs.List
			aria-label="People by status"
			class="h-auto w-full flex-wrap justify-start gap-2 bg-transparent p-0"
		>
			{#each groups as group (group.key)}
				<Tabs.Trigger
					value={group.key}
					class="min-h-11 flex-none gap-2 rounded-lg border-border px-3 py-2 data-[state=active]:border-primary data-[state=active]:bg-primary/10 data-[state=active]:text-primary data-[state=active]:shadow-none"
				>
					{group.title}
					<Badge variant="outline">{group.intakes.length}</Badge>
				</Tabs.Trigger>
			{/each}
		</Tabs.List>
		{#key active.key}
			<Tabs.Content value={active.key} class="space-y-4">
				{#if (active.key === "all" || active.key === "awaitingPayment") && unpaid.length}
					<p
						class="rounded-lg bg-muted/50 p-3 text-sm text-muted-foreground"
						data-testid="payment-guidance"
					>
						{#if overdue.size}
							{overdue.size}
							{overdue.size === 1 ? "reply period has" : "reply periods have"} ended.
						{/if}
						No follow-up is required. People can still pay until the payment deadline.
						At that deadline, unpaid people are automatically removed from the waitlist,
						or returned to it if the workshop is full. Anyone still checking out keeps
						their reserved place until checkout ends.
					</p>
				{/if}
				{#if (active.key === "all" || active.key === "awaitingConfirmation") && unconfirmed.length}
					<p
						class="rounded-lg bg-muted/50 p-3 text-sm text-muted-foreground"
						data-testid="confirmation-guidance"
					>
						People with workshop credit can confirm until the workshop is
						finished. No follow-up is required. If they reply by email, you can
						confirm their place for them.
					</p>
				{/if}
				{#if active.intakes.length}
					<ul class="space-y-2" aria-label="Workshop people">
						{#each active.intakes as intake (intake.id)}
							{@const refund = refundLabel(intake)}
							<li
								class="flex flex-wrap items-center gap-2"
								data-testid="person-row"
							>
								<Button
									variant="outline"
									class="h-auto min-h-11 min-w-0 flex-1 flex-wrap justify-start gap-3 rounded-xl bg-background/50 px-4 py-3 text-left font-normal whitespace-normal shadow-none focus-visible:border-primary"
									aria-label={`${personName(intake)} — ${intakeStateLabel(intake.state)} — View person`}
									onclick={() => onSelect(intake.id)}
								>
									<span class="min-w-0 flex-1 basis-48">
										<span class="block font-medium">{personName(intake)}</span>
										{#if intake.state === "contacted"}
											<span
												class="block text-xs text-muted-foreground"
												data-testid="reply-period"
											>
												{#if intake.carriedFee === "held"}
													{unconfirmedCarriedFeeText(intake)}
												{:else if overdue.has(intake.id)}
													{unpaidAfterWindowText(intake)}
												{:else}
													Reply period ends {formatDublinInstant(
														intake.windowEndsAt,
													)}
												{/if}
											</span>
										{/if}
									</span>
									{#if intake.minor}<Badge variant="outline">Minor</Badge>{/if}
									<span class="text-xs text-muted-foreground"
										>{intakeOrigin(intake)}</span
									>
									{#if refund}
										<Badge
											variant="outline"
											class={cn(
												refund.tone === "failed" &&
													"border-destructive bg-destructive text-white",
												refund.tone === "progress" &&
													"border-amber-500 text-amber-900",
												refund.tone === "done" &&
													"border-emerald-700 text-emerald-900",
											)}
											data-testid="refund-status">{refund.text}</Badge
										>
									{/if}
									{#if carriedFeeLabel(intake.carriedFee)}
										<Badge
											variant="outline"
											data-testid="carried-fee"
											class="capitalize"
											>{carriedFeeLabel(intake.carriedFee)}</Badge
										>
									{/if}
									{#if holdLabel(intake)}
										<Badge
											variant="outline"
											class="border-sky-600 text-sky-800"
											data-testid="hold-expiry">{holdLabel(intake)}</Badge
										>
									{/if}
									{#if intake.checkedInAt}
										<Badge
											variant="outline"
											class="border-emerald-600 text-emerald-800"
											data-testid="checked-in"
											>In {formatDublinTime(intake.checkedInAt)}</Badge
										>
									{/if}
									<Badge variant="outline">
										{intake.state === "contacted"
											? intake.carriedFee === "held"
												? "Awaiting confirmation"
												: "Awaiting payment"
											: intakeStateLabel(intake.state)}
									</Badge>
									<span class="text-sm font-semibold text-primary"
										>View person</span
									>
								</Button>
								{#if intake.state === "attended"}
									{#if intake.standing === "attended" && canInvite}
										<InviteButton
											workshopId={view.workshop.id}
											intakeId={intake.id}
											name={personName(intake)}
										/>
									{:else if standingLabel(intake.standing)}
										<Badge
											variant="outline"
											class="border-emerald-700 text-emerald-900"
											data-testid="invitation-standing"
											>{standingLabel(intake.standing)}</Badge
										>
									{/if}
								{/if}
							</li>
						{/each}
					</ul>
				{:else}
					<Empty.Root class="border">
						<Empty.Header>
							<Empty.Title
								>{groups[0]!.intakes.length
									? "No people in this group"
									: "Nobody contacted yet"}</Empty.Title
							>
							<Empty.Description>
								{#if groups[0]!.intakes.length}
									Choose another status to view the other people in this
									workshop.
								{:else}
									People appear here after they receive a place offer,
									automatically or from staff.
								{/if}
							</Empty.Description>
						</Empty.Header>
					</Empty.Root>
				{/if}
			</Tabs.Content>
		{/key}
	</Tabs.Root>
</section>
