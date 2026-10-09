<!-- PROTOTYPE — throwaway (ALE-372). Invitable view (ALE-371): everyone whose attendance
     is final and who hasn't been sent an Invitation yet, across every workshop. One click
     per person, no bulk; a refusal comes back synchronously and stays on the row. -->
<script lang="ts">
import { ArrowLeft } from "@lucide/svelte";
import dayjs from "dayjs";
import { Button } from "#lib/components/ui/button/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import { go } from "./bw-nav";
import { fmtDay, NOW, proto } from "./bw-prototype-store.svelte";

const rows = $derived(proto.invitable());
const refused = $derived(
	proto.people.filter(
		(person) =>
			proto.inviteRefusals[person.id] && person.standing !== "attended",
	),
);
</script>

<div class="flex flex-col gap-5">
	<button
		type="button"
		class="flex w-fit cursor-pointer items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
		onclick={() => go("workshops")}
	>
		<ArrowLeft class="size-4" /> Beginners' Workshops
	</button>
	<header>
		<h1 class="font-heading text-3xl">Invitable</h1>
		<p class="max-w-3xl text-sm text-muted-foreground">
			Attended a Beginners' Workshop, no Invitation yet. Inviting doesn't wait
			for the follow-up email. The Invitation is the standard tier with a 7-day
			expiry; resend and delete live in Members → Invitations, as today.
		</p>
	</header>

	<div class="rounded-xl border bg-card">
		<Table.Root>
			<Table.Header>
				<Table.Row>
					<Table.Head>Name</Table.Head>
					<Table.Head>Attended</Table.Head>
					<Table.Head class="hidden md:table-cell">Follow-up</Table.Head>
					<Table.Head class="text-right"
						><span class="sr-only">Invite</span></Table.Head
					>
				</Table.Row>
			</Table.Header>
			<Table.Body>
				{#each rows as row (row.person.id)}
					{@const refusal = proto.inviteRefusals[row.person.id]}
					<Table.Row>
						<Table.Cell>
							<span class="font-medium"
								>{row.person.firstName} {row.person.lastName}</span
							>
							<span class="block text-xs text-muted-foreground"
								>{row.person.email}</span
							>
							{#if row.person.invitationNote}<span
									class="block text-xs text-muted-foreground"
									>{row.person.invitationNote}</span
								>{/if}
						</Table.Cell>
						<Table.Cell>
							<button
								type="button"
								class="cursor-pointer underline-offset-2 hover:underline"
								onclick={() => go("console", row.workshop.id)}
								>{fmtDay(row.workshop.date)}</button
							>
							<span class="block text-xs text-muted-foreground"
								>{dayjs(NOW).diff(row.workshop.date, "day")} days ago</span
							>
						</Table.Cell>
						<Table.Cell
							class="hidden text-sm text-muted-foreground md:table-cell"
						>
							{row.intake.emails.some((entry) => entry.type === "follow_up")
								? "Sent"
								: "Scheduled"}
						</Table.Cell>
						<Table.Cell class="text-right">
							<div class="flex flex-col items-end gap-1">
								<Button
									size="sm"
									onclick={() => proto.sendInvitation(row.person.id)}
									>Invite</Button
								>
								{#if refusal}<span class="text-xs text-destructive"
										>Refused: {refusal}</span
									>{/if}
							</div>
						</Table.Cell>
					</Table.Row>
				{:else}
					<Table.Row
						><Table.Cell
							colspan={4}
							class="py-8 text-center text-muted-foreground"
							>Nobody to invite. People appear here once a workshop is
							finalised.</Table.Cell
						></Table.Row
					>
				{/each}
			</Table.Body>
		</Table.Root>
	</div>

	{#if refused.length}
		<div
			class="rounded-xl border border-destructive/40 bg-destructive/5 p-3 text-sm"
		>
			{#each refused as person (person.id)}
				<p>
					<strong>{person.firstName} {person.lastName}</strong> left this list:
					Invite refused {proto.inviteRefusals[person.id]} (someone else invited them
					first).
				</p>
			{/each}
		</div>
	{/if}
</div>
