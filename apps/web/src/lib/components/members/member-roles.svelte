<script lang="ts">
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import {
	memberRolesShowOptions,
	memberRolesShowQueryKey,
	memberRolesUpdateMutation,
} from "@dhc/api-client";
import { toast } from "svelte-sonner";
import { apiProblem, apiErrorMessage } from "#lib/api-error.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Card from "#lib/components/ui/card/index.js";
import { Skeleton } from "#lib/components/ui/skeleton/index.js";
import RoleEditor from "./role-editor.svelte";

let { memberId, isOwnProfile }: { memberId: string; isOwnProfile: boolean } =
	$props();
const queryClient = useQueryClient();
const rolesQuery = createQuery(() => ({
	...memberRolesShowOptions({ path: { memberId } }),
	refetchOnWindowFocus: false,
	refetchOnReconnect: false,
}));
const mutation = createMutation(() => ({
	...memberRolesUpdateMutation(),
	onSuccess: (response) => {
		queryClient.setQueryData(
			memberRolesShowQueryKey({ path: { memberId } }),
			response,
		);
		toast.success(
			"Roles saved. This member has been signed out on all devices.",
		);
		if (isOwnProfile) window.location.assign("/auth");
	},
}));
const problem = $derived(apiProblem(mutation.error));
</script>

{#if rolesQuery.data}
	{#key rolesQuery.data}
		<RoleEditor
			roles={rolesQuery.data.data.roles}
			availableRoles={rolesQuery.data.data.availableRoles}
			pending={mutation.isPending}
			error={mutation.isError
				? apiErrorMessage(mutation.error, "Could not save roles. Try again.")
				: null}
			stale={problem?.code === "roles_changed"}
			{isOwnProfile}
			onSave={(roles) =>
				mutation.mutate({
					path: { memberId },
					body: { roles, expectedRoles: rolesQuery.data?.data.roles ?? [] },
				})}
			onReload={async () => {
				const result = await rolesQuery.refetch();
				if (result.isSuccess) mutation.reset();
			}}
		/>
	{/key}
{:else}
	<Card.Root>
		<Card.Header><h2 class="text-lg font-semibold">Club roles</h2></Card.Header>
		<Card.Content>
			{#if rolesQuery.isError}
				<p role="alert" class="mb-3 text-sm text-destructive">
					{apiErrorMessage(rolesQuery.error, "Could not load roles.")}
				</p>
				<Button
					type="button"
					variant="outline"
					onclick={() => rolesQuery.refetch()}>Retry loading roles</Button
				>
			{:else}
				<Skeleton class="h-32 w-full" />
				<p role="status" class="sr-only">Loading roles…</p>
			{/if}
		</Card.Content>
	</Card.Root>
{/if}
