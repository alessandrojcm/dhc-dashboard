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
		note: "Median from queue date to workshop (Batch Intakes)",
	},
	{
		label: "Workshops to clear the queue",
		value: formatFigure(queue.workshopsToClear),
		note: `${queue.waiting} waiting ÷ ${formatFigure(months.averageAttendees)} attendees per workshop`,
	},
	{
		label: "Conversion Rate",
		value: formatRate(months.conversionRate),
		note: `${months.joined} joined of ${months.attended} attended · ${months.invitable} Invitable · ${months.invitedNotJoined} invited, not yet joined`,
	},
]);

const liabilities = $derived([
	{
		label: "Removed, within retention",
		value: String(queue.removedInRetention),
		note: "Can still be restored",
	},
	{
		label: "Invitable",
		value: String(queue.invitable),
		note: "Attended, not yet invited",
	},
	{
		label: "Outstanding Carried Fees",
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
			Intake counts, newest first. Rates are out of the people who could take
			each step; attendance is out of the people still seated at finalisation.
		</p>
	</div>

	{#if report.outcomes.length === 0}
		<Empty.Root class="border">
			<Empty.Header>
				<Empty.Title>No past workshops yet</Empty.Title>
				<Empty.Description>
					Outcomes appear once a workshop is finalised or cancelled.
				</Empty.Description>
			</Empty.Header>
		</Empty.Root>
	{:else}
		<div class="overflow-x-auto rounded-lg border">
			<Table.Root>
				<Table.Header>
					<Table.Row>
						<Table.Head>Workshop</Table.Head>
						<Table.Head class="text-right">Contacted</Table.Head>
						<Table.Head class="text-right">Left before paying</Table.Head>
						<Table.Head class="text-right">Paid</Table.Head>
						<Table.Head class="text-right">Left after paying</Table.Head>
						<Table.Head class="text-right">Attendance</Table.Head>
						<Table.Head class="text-right">After attending</Table.Head>
						<Table.Head class="text-right">Conversion Rate</Table.Head>
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{#each report.outcomes as outcome (outcome.workshopId)}
						{@const open = expanded.has(outcome.workshopId)}
						<Table.Row data-testid="report-outcome" class="align-top">
							<Table.Cell>
								<div class="flex items-start gap-2">
									<Button
										variant="ghost"
										size="icon"
										class="size-7"
										aria-expanded={open}
										aria-label={`${open ? "Hide" : "Show"} Batches for ${formatCivilDate(outcome.date)}`}
										onclick={() => toggle(outcome.workshopId)}
									>
										{#if open}<ChevronDown />{:else}<ChevronRight />{/if}
									</Button>
									<div>
										<p class="font-medium text-foreground">
											{formatCivilDate(outcome.date)}
											{#if cancelled(outcome)}
												<Badge variant="destructive" class="ml-1"
													>Cancelled</Badge
												>
											{/if}
										</p>
										<p class="text-xs text-muted-foreground">
											{outcome.venue} · Batches sent: {outcome.batchesSent}
										</p>
										<a
											class="mt-1 inline-flex items-center gap-1 text-xs text-primary underline-offset-2 hover:underline"
											href={resolve(
												"/dashboard/beginners-workshop/workshops/[workshopId]",
												{ workshopId: outcome.workshopId },
											)}
										>
											<PanelsTopLeft class="size-3" aria-hidden="true" /> Console
										</a>
									</div>
								</div>
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{outcome.contacted.total}
								<p class="text-xs text-muted-foreground">
									{outcome.contacted.batch} Batch · {outcome.contacted
										.fastTrack} fast-track
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
										{outcome.paid.carriedFee} with a Carried Fee
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
										no-show
									</p>
								{/if}
							</Table.Cell>
							<Table.Cell class="text-right tabular-nums">
								{#if cancelled(outcome)}
									—
								{:else}
									{outcome.afterAttending.joined} joined
									<p class="text-xs text-muted-foreground">
										{outcome.afterAttending.invitable} Invitable · {outcome
											.afterAttending.invitedNotJoined} invited, not yet joined
									</p>
								{/if}
							</Table.Cell>
							<Table.Cell class="text-right font-semibold tabular-nums">
								{formatRate(outcome.conversionRate)}
							</Table.Cell>
						</Table.Row>
						{#if open}
							<Table.Row
								data-testid="report-groups"
								class="bg-muted/30 hover:bg-muted/30"
							>
								<Table.Cell colspan={8} class="p-0">
									{#if outcome.groups.length === 0}
										<p class="px-4 py-3 text-sm text-muted-foreground">
											Nobody was contacted.
										</p>
									{:else}
										<Table.Root>
											<Table.Header>
												<Table.Row>
													<Table.Head class="pl-12">Contact round</Table.Head>
													<Table.Head class="text-right">Contacted</Table.Head>
													<Table.Head class="text-right"
														>Paid within the window</Table.Head
													>
													<Table.Head class="text-right">Paid later</Table.Head>
													<Table.Head class="text-right">Declined</Table.Head>
													<Table.Head class="text-right"
														>Unpaid at cutoff</Table.Head
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
																	Window to {formatDublinInstant(
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
		</div>
	{/if}
</section>
