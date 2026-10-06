<script lang="ts">
import type { ClubRole } from "@dhc/api-client";
import { untrack } from "svelte";
import { Button } from "#lib/components/ui/button/index.js";
import { Checkbox } from "#lib/components/ui/checkbox/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import * as Card from "#lib/components/ui/card/index.js";

let {
	roles,
	availableRoles,
	pending = false,
	error = null,
	stale = false,
	isOwnProfile = false,
	onSave,
	onReload,
}: {
	roles: ClubRole[];
	availableRoles: ClubRole[];
	pending?: boolean;
	error?: string | null;
	stale?: boolean;
	isOwnProfile?: boolean;
	onSave: (roles: ClubRole[]) => void;
	onReload: () => void;
} = $props();

let selected = $state<ClubRole[]>(untrack(() => [...roles]));
const changed = $derived(
	selected.length !== roles.length ||
		selected.some((role) => !roles.includes(role)),
);

function toggle(role: ClubRole, checked: boolean) {
	selected = checked
		? [...selected, role]
		: selected.filter((value) => value !== role);
}
</script>

<Card.Root>
	<Card.Header>
		<h2 class="text-lg font-semibold">Club roles</h2>
		<Card.Description
			>Choose the roles this member holds. Role changes are saved separately
			from profile changes.</Card.Description
		>
	</Card.Header>
	<Card.Content class="space-y-5">
		<fieldset
			disabled={pending || stale}
			aria-describedby="roles-help"
			class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3"
		>
			<legend class="sr-only">Assigned club roles</legend>
			{#each availableRoles as role (role)}
				<Label
					for={`role-${role}`}
					class="flex min-h-12 cursor-pointer items-center gap-3 rounded-lg border border-border p-3 has-[[data-state=checked]]:bg-primary/5"
				>
					<Checkbox
						id={`role-${role}`}
						checked={selected.includes(role)}
						disabled={pending || stale}
						onCheckedChange={(checked) => toggle(role, checked)}
					/>
					<span class="capitalize">{role.replaceAll("_", " ")}</span>
				</Label>
			{/each}
		</fieldset>
		<p id="roles-help" class="text-sm text-muted-foreground">
			Saving a role change immediately signs this member out on all devices.
			They must sign in again to use their new roles.
			{#if isOwnProfile}You are editing your own roles and will also be signed
				out.{/if}
			Keep at least one active president or admin.
		</p>
		{#if error}<p role="alert" class="text-sm text-destructive">{error}</p>{/if}
		<div class="flex flex-wrap gap-2">
			<Button
				type="button"
				disabled={!changed || pending || stale}
				onclick={() => onSave(selected)}
			>
				{pending ? "Saving roles…" : "Save roles"}
			</Button>
			<Button
				type="button"
				variant="outline"
				disabled={pending}
				onclick={() => {
					selected = [...roles];
					if (stale) onReload();
				}}>{stale ? "Reload roles" : "Reset"}</Button
			>
		</div>
		<span class="sr-only" aria-live="polite"
			>{pending ? "Saving club roles" : ""}</span
		>
	</Card.Content>
</Card.Root>
