<!-- PROTOTYPE — throwaway (ALE-372). Every staff command that needs input opens here,
     driven by `proto.dialog`; the Intake Sheet is driven by `proto.sheetIntakeId`. -->
<script lang="ts">
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import { proto } from "./bw-prototype-store.svelte";
import CommandDialogBody from "./command-dialog-body.svelte";
import IntakeDetail from "./intake-detail.svelte";
</script>

<Dialog.Root
	open={proto.dialog !== null}
	onOpenChange={(next) => !next && (proto.dialog = null)}
>
	<Dialog.Content class="max-h-[90dvh] overflow-y-auto sm:max-w-lg">
		{#if proto.dialog}
			{#key proto.dialog}
				<CommandDialogBody request={proto.dialog} />
			{/key}
		{/if}
	</Dialog.Content>
</Dialog.Root>

<Sheet.Root
	open={proto.sheetIntakeId !== null}
	onOpenChange={(next) => !next && (proto.sheetIntakeId = null)}
>
	<Sheet.Content side="right" class="w-full overflow-y-auto p-6 sm:max-w-md">
		<Sheet.Header class="p-0">
			<Sheet.Title class="sr-only">Intake</Sheet.Title>
		</Sheet.Header>
		{#if proto.sheetIntakeId}
			<IntakeDetail intakeId={proto.sheetIntakeId} />
		{/if}
	</Sheet.Content>
</Sheet.Root>
