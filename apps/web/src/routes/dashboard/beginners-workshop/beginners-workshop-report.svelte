<!--
	ALE-397: the Beginners' Workshop report on the Dashboard tab — planning
	cards (the last 12 months by workshop date) and the outcomes table of
	past workshops, newest first. Every figure is Phoenix's
	(`GET /api/beginners-workshops/report`); this component only lays them
	out. Report only: it offers no command, and a row links to its console.
-->
<script lang="ts">
import type {
	BeginnersWorkshopReport,
	BeginnersWorkshopReportOutcome,
} from "@dhc/api-client";
import { ChevronDown, ChevronRight, PanelsTopLeft } from "@lucide/svelte";
import { resolve } from "$app/paths";
import { SvelteSet } from "svelte/reactivity";
import { formatCivilDate } from "#lib/beginners-workshops/presentation.js";
import { formatDublinInstant } from "#lib/beginners-workshops/console.js";
import {
	carriedFeesNote,
	countWithRate,
	exitsAfterPayingDetail,
	exitsBeforePayingDetail,
	formatDays,
	formatFigure,
	formatRate,
	groupLabel,
} from "#lib/beginners-workshops/report.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Card from "#lib/components/ui/card/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import * as Table from "#lib/components/ui/table/index.js";

const { report }: { report: BeginnersWorkshopReport } = $props();

const expanded = new SvelteSet<string>();

function toggle(id: string) {
	if (expanded.has(id)) expanded.delete(id);
	else expanded.add(id);
}

const queue = $derived(report.queue);
const months = $derived(report.twelveMonths);

const planning = $derived([
	{
		label: "Time to a seat",
		value: formatDays(queue.medianDaysToSeat),
		note: "Typical wait from joining the waitlist to the workshop date, for automatic place offers",
	},
	{
		label: "Workshops to clear the queue",
		value: formatFigure(queue.workshopsToClear),
		note: `${queue.waiting} waiting ÷ ${formatFigure(months.averageAttendees)} attendees per workshop`,
	},
	{
		label: "Attendees who joined the club",
		value: formatRate(months.conversionRate),
		note: `${months.joined} joined of ${months.attended} attendees · ${months.invitable} ready to invite · ${months.invitedNotJoined} invited, not yet joined`,
	},
]);

const liabilities = $derived([
	{
		label: "Can be restored to the waitlist",
		value: String(queue.removedInRetention),
		note: "People removed within the last 3 months",
	},
	{
		label: "Ready for a membership invitation",
		value: String(queue.invitable),
		note: "Attended, not yet invited",
	},
	{
		label: "People with workshop credit",
		value: String(queue.carriedFees.count),
		note: carriedFeesNote(queue.carriedFees),
	},
]);

function cancelled(outcome: BeginnersWorkshopReportOutcome) {
	return outcome.status === "cancelled";
}
</script>

<section aria-labelledby="bw-report-planning" class="mt-8">
	<div class="mb-4">
		<p class="text-xs font-bold uppercase tracking-[0.16em] text-primary">
			Planning
		</p>
		<h2
			id="bw-report-planning"
			class="mt-1 font-heading text-2xl text-foreground"
		>
			The last 12 months
		</h2>
		<p class="text-sm text-muted-foreground">
			{months.workshops}
			{months.workshops === 1 ? "workshop" : "workshops"} by workshop date; cancelled
			workshops are left out.
		</p>
	</div>

	<div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
		{#each planning as card (card.label)}
			<Card.Root class="gap-0 p-4 sm:p-5" data-testid="report-card">
				<p class="text-sm font-semibold text-muted-foreground">{card.label}</p>
				<p
					class="mt-3 text-2xl font-bold tabular-nums text-foreground sm:text-3xl"
				>
					{card.value}
				</p>
				<p class="mt-2 text-xs leading-5 text-muted-foreground">{card.note}</p>
			</Card.Root>
		{/each}
	</div>

	<div class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3">
		{#each liabilities as card (card.label)}
			<Card.Root class="gap-0 p-4 sm:p-5" data-testid="report-card">
				<p class="text-sm font-semibold text-muted-foreground">{card.label}</p>
				<p class="mt-3 text-2xl font-bold tabular-nums text-foreground">
					{card.value}
				</p>
				<p class="mt-2 text-xs leading-5 text-muted-foreground">{card.note}</p>
			</Card.Root>
		{/each}
	</div>
</section>

<section aria-labelledby="bw-report-outcomes" class="mt-8">
	<div class="mb-4">
		<p class="text-xs font-bold uppercase tracking-[0.16em] text-primary">
			Outcomes
		</p>
		<h2
			id="bw-report-outcomes"
			class="mt-1 font-heading text-2xl text-foreground"
		>
			Past workshops
		</h2>
		<p class="text-sm text-muted-foreground">
			People offered a place at each workshop, newest first. Attendance rates
			count confirmed places when attendance was recorded; membership rates
			count those who attended.
		</p>
	</div>

	{#if report.outcomes.length === 0}
		<Empty.Root class="border">
			<Empty.Header>
				<Empty.Title>No past workshops yet</Empty.Title>
				<Empty.Description>
					Results appear after attendance is confirmed or a workshop is
					cancelled.
				</Empty.Description>
			</Empty.Header>
		</Empty.Root>
	{:else}
		<div
			class="overflow-hidden rounded-lg border border-border bg-card text-card-foreground shadow-sm"
		>
			<Table.Root
				class="min-w-[1120px] text-[0.8125rem] [&_td]:px-3 [&_td]:py-2 [&_td]:whitespace-normal [&_td]:font-semibold [&_td_p]:mt-0.5 [&_td_p]:text-xs [&_td_p]:font-normal [&_td_p]:leading-4 [&_th]:h-10 [&_th]:px-3 [&_th]:whitespace-normal [&_th]:font-semibold"
			>
				<Table.Caption class="sr-only"
					>Past workshop outcomes, newest first. Expand a workshop to see its
					contact rounds.</Table.Caption
				>
				<Table.Header class="bg-primary [&_th]:text-primary-foreground">
					<Table.Row class="border-primary hover:bg-primary">
						<Table.Head>Workshop</Table.Head>
						<Table.Head class="text-right">Contacted</Table.Head>
						<Table.Head class="text-right">Left before paying</Table.Head>
						<Table.Head class="text-right">Paid</Table.Head>
						<Table.Head class="text-right">Left after paying</Table.Head>
						<Table.Head class="text-right">Attendance</Table.Head>
						<Table.Head class="text-right">After attending</Table.Head>
						<Table.Head class="text-right">Joined the club</Table.Head>
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{#each report.outcomes as outcome (outcome.workshopId)}
						{@const open = expanded.has(outcome.workshopId)}
						<Table.Row
							data-testid="report-outcome"
							class="align-top text-foreground transition-colors even:bg-muted/25 hover:bg-muted/50"
						>
							<Table.Cell>
								<div class="flex items-start gap-2">
									<Button
										variant="ghost"
										size="icon"
										class="size-11 shrink-0 text-primary hover:bg-muted hover:text-primary sm:size-8"
										aria-expanded={open}
										aria-label={`${open ? "Hide" : "Show"} offer rounds for ${formatCivilDate(outcome.date)}`}
										onclick={() => toggle(outcome.workshopId)}
									>
										{#if open}<ChevronDown />{:else}<ChevronRight />{/if}
									</Button>
									<div class="min-w-48 max-w-64">
										<p class="font-semibold text-foreground">
											{formatCivilDate(outcome.date)}
											{#if cancelled(outcome)}
												<Badge variant="destructive" class="ml-1"
													>Cancelled</Badge
												>
											{/if}
										</p>
										<p class="text-xs text-muted-foreground">
											{outcome.venue} · Offer rounds: {outcome.batchesSent}
										</p>
										<a
											class="mt-1 inline-flex min-h-11 items-center gap-1 text-xs font-medium text-primary underline underline-offset-4 hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring sm:min-h-6"
											href={resolve(
												"/dashboard/beginners-workshop/workshops/[workshopId]",
												{ workshopId: outcome.workshopId },
											)}
										>
											<PanelsTopLeft class="size-3" aria-hidden="true" /> Manage
										</a>
									</div>
								</div>
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{outcome.contacted.total}
								<p class="text-xs text-muted-foreground">
									{outcome.contacted.batch} automatic · {outcome.contacted
										.fastTrack} added by staff
								</p>
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{countWithRate(
									outcome.exitsBeforePaying.total,
									outcome.exitsBeforePaying.rate,
								)}
								<p class="text-xs text-muted-foreground">
									{exitsBeforePayingDetail(outcome.exitsBeforePaying)}
								</p>
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{outcome.paid.total}
								{#if outcome.paid.carriedFee > 0}
									<p class="text-xs text-muted-foreground">
										{outcome.paid.carriedFee} using credit
									</p>
								{/if}
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{countWithRate(
									outcome.exitsAfterPaying.total,
									outcome.exitsAfterPaying.rate,
								)}
								<p class="text-xs text-muted-foreground">
									{exitsAfterPayingDetail(outcome.exitsAfterPaying)}
								</p>
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{#if cancelled(outcome)}
									—
								{:else}
									{formatRate(outcome.attendance.rate)}
									<p class="text-xs text-muted-foreground">
										{outcome.attendance.attended} attended · {outcome.attendance
											.noShow}
										did not attend
									</p>
								{/if}
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{#if cancelled(outcome)}
									—
								{:else}
									{outcome.afterAttending.joined} joined
									<p class="text-xs text-muted-foreground">
										{outcome.afterAttending.invitable} ready to invite · {outcome
											.afterAttending.invitedNotJoined} invited, not yet joined
									</p>
								{/if}
							</Table.Cell>
							<Table.Cell
								class="bg-primary/5 text-right font-semibold tabular-nums text-primary"
							>
								{formatRate(outcome.conversionRate)}
							</Table.Cell>
						</Table.Row>
						{#if open}
							<Table.Row
								data-testid="report-groups"
								class="bg-muted/50 hover:bg-muted/50"
							>
								<Table.Cell colspan={8} class="!p-0">
									{#if outcome.groups.length === 0}
										<p class="px-4 py-3 text-sm text-muted-foreground">
											Nobody was contacted.
										</p>
									{:else}
										<Table.Root
											aria-label={`Contact rounds for ${formatCivilDate(outcome.date)}`}
											class="border-l-4 border-primary/40"
										>
											<Table.Header class="bg-muted [&_th]:text-foreground">
												<Table.Row class="hover:bg-muted">
													<Table.Head class="pl-12">Offer round</Table.Head>
													<Table.Head class="text-right">Contacted</Table.Head>
													<Table.Head class="text-right"
														>Paid within reply period</Table.Head
													>
													<Table.Head class="text-right">Paid later</Table.Head>
													<Table.Head class="text-right">Declined</Table.Head>
													<Table.Head class="text-right"
														>Unpaid at deadline</Table.Head
													>
												</Table.Row>
											</Table.Header>
											<Table.Body>
												{#each outcome.groups as group (group.kind + (group.number ?? ""))}
													<Table.Row data-testid="report-group">
														<Table.Cell class="pl-12">
															{groupLabel(group)}
															{#if group.windowEndsAt}
																<p class="text-xs text-muted-foreground">
																	Reply by {formatDublinInstant(
																		group.windowEndsAt,
																	)}
																</p>
															{/if}
														</Table.Cell>
														<Table.Cell class="text-right tabular-nums"
															>{group.contacted}</Table.Cell
														>
														<Table.Cell class="text-right tabular-nums"
															>{group.paidInWindow}</Table.Cell
														>
														<Table.Cell class="text-right tabular-nums"
															>{group.paidLater}</Table.Cell
														>
														<Table.Cell class="text-right tabular-nums"
															>{group.declined}</Table.Cell
														>
														<Table.Cell class="text-right tabular-nums"
															>{group.unpaidAtCutoff}</Table.Cell
														>
													</Table.Row>
												{/each}
											</Table.Body>
										</Table.Root>
									{/if}
								</Table.Cell>
							</Table.Row>
						{/if}
					{/each}
				</Table.Body>
			</Table.Root>
			<div
				class="flex flex-wrap items-center justify-between gap-2 border-t border-border bg-muted/40 px-3 py-2 text-xs text-muted-foreground"
			>
				<p class="font-semibold text-foreground">
					{report.outcomes.length}
					{report.outcomes.length === 1 ? "workshop" : "workshops"}
				</p>
				<p>Expand a row to see automatic offers and people added by staff.</p>
			</div>
		</div>
	{/if}
</section>
