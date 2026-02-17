<script lang="ts">
	import * as Sheet from '$lib/components/ui/sheet/index.js';
	import * as Field from '$lib/components/ui/field';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Lock } from 'lucide-svelte';
	import { toast } from 'svelte-sonner';
	import { updateMemberSettings } from './data.remote';
    import { initForm } from '$lib/utils/init-form.svelte';
	
	const props: {
		initialValue: string;
	} = $props();
	let isOpen = $state(false);

	initForm(updateMemberSettings, () => ({
		insuranceFormLink: props.initialValue,
	}));

	$effect(() => {
		const result = updateMemberSettings.result;
		if (result?.success) {
			toast.success(result.success);
			isOpen = false;
		}
	});
</script>

<Button variant="outline" class="fixed right-4 top-4" onclick={() => (isOpen = true)}>
	<Lock class="mr-2 h-4 w-4" />
	Settings
</Button>

<Sheet.Root bind:open={isOpen}>
	<Sheet.Content class="w-full">
		<Sheet.Header>
			<Sheet.Title>Settings</Sheet.Title>
			<Sheet.Description>Configure your members settings here.</Sheet.Description>
		</Sheet.Header>
		<form {...updateMemberSettings} class="space-y-4 mt-4 p-8">
			<Field.Field>
				{@const fieldProps = updateMemberSettings.fields.insuranceFormLink.as('url')}
				<Field.Label for={fieldProps.name}>HEMA Insurance Form Link</Field.Label>
				<Input
					{...fieldProps}
					id={fieldProps.name}
					placeholder="https://example.com/insurance-form"
				/>
				{#each updateMemberSettings.fields.insuranceFormLink.issues() as issue}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
			</Field.Field>
			<Button type="submit" class="w-full">
				Save Settings
			</Button>
		</form>
	</Sheet.Content>
</Sheet.Root>
