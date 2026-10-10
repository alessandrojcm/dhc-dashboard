<!--
	ALE-379: the two Staff pickers shared by the Schedule and Staff dialogs —
	a searchable coach select that lists only coaches, and a multi-select of
	assistants (any active Member, coaches included) with removable chips.
	Picking someone as coach removes them from the assistants; Phoenix does
	the same and decides who may be assigned. Someone already on the Staff
	stays pickable even if they would no longer be offered (a coach whose
	coach role was removed keeps the assignment).

	The owning form renders the hidden inputs from `coach` and `assistants`.
-->
<script lang="ts">
import type {
	BeginnersWorkshopStaff,
	BeginnersWorkshopStaffCandidate,
} from "@dhc/api-client";
import * as Combobox from "#lib/components/ui/combobox/index.js";
import * as Field from "#lib/components/ui/field/index.js";

let {
	idPrefix,
	candidates,
	current = { coach: null, assistants: [] },
	coach = $bindable(""),
	assistants = $bindable([]),
	coachIssues = [],
	assistantIssues = [],
}: {
	idPrefix: string;
	candidates: BeginnersWorkshopStaffCandidate[];
	/** The Staff already assigned, kept pickable. */
	current?: BeginnersWorkshopStaff;
	coach?: string;
	assistants?: string[];
	coachIssues?: { message: string }[];
	assistantIssues?: { message: string }[];
} = $props();

type Item = Combobox.ComboboxItem;

const candidateItems = $derived(
	candidates.map((candidate) => ({
		value: candidate.principalId,
		label: candidate.name,
		badge: candidate.coach ? "coach" : undefined,
	})),
);

function withCurrent(
	items: Item[],
	extra: { principalId: string; name: string }[],
) {
	const known = new Set(items.map((item) => item.value));
	return [
		...items,
		...extra
			.filter((member) => !known.has(member.principalId))
			.map((member) => ({ value: member.principalId, label: member.name })),
	];
}

const coachItems = $derived(
	withCurrent(
		candidateItems.filter((item) => item.badge === "coach"),
		current.coach ? [current.coach] : [],
	),
);

const assistantItems = $derived(
	withCurrent(candidateItems, [
		...current.assistants,
		...(current.coach ? [current.coach] : []),
	]).filter((item) => item.value !== coach),
);

function pickCoach(value: string[]) {
	coach = value[0] ?? "";
	assistants = assistants.filter((id) => id !== coach);
}
</script>

<Field.Group class="grid gap-4">
	<Field.Field>
		<Field.Label for={`${idPrefix}-coach`}>
			Coach
			<span class="font-normal text-muted-foreground"
				>(Members with the coach role)</span
			>
		</Field.Label>
		<Combobox.Root
			id={`${idPrefix}-coach`}
			label="Coach"
			placeholder="No coach yet (Unstaffed)"
			searchPlaceholder="Search coaches…"
			emptyText="No coach found."
			clearLabel="Clear coach (Unstaffed)"
			items={coachItems}
			value={coach ? [coach] : []}
			onValueChange={pickCoach}
		/>
		{#each coachIssues as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>
	<Field.Field>
		<Field.Label for={`${idPrefix}-assistants`}>
			Assistants
			<span class="font-normal text-muted-foreground"
				>(any active Member, coaches included)</span
			>
		</Field.Label>
		<Combobox.Root
			id={`${idPrefix}-assistants`}
			label="Assistants"
			placeholder="Add assistants"
			searchPlaceholder="Search Members…"
			emptyText="No Member found."
			multiple
			items={assistantItems}
			value={assistants}
			onValueChange={(value) => (assistants = value)}
		/>
		{#each assistantIssues as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>
</Field.Group>
