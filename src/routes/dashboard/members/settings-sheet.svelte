<script lang="ts">
	import * as Sheet from '$lib/components/ui/sheet/index.js';
	import * as Form from '$lib/components/ui/form';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Lock } from 'lucide-svelte';
	import { superForm, type SuperValidated } from 'sveltekit-superforms/client';
	import type { MemberSettingsOutput } from '$lib/schemas/membersSettings';
	import memberSettingsSchema from '$lib/schemas/membersSettings';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { toast } from 'svelte-sonner';

	const props: {
		form: SuperValidated<MemberSettingsOutput, any, MemberSettingsOutput>;
	} = $props();
	let isOpen = $state(false);

	const form = superForm(props.form, {
		resetForm: false,
		validators: valibotClient(memberSettingsSchema),
		onResult: ({ result }) => {
			result.type === 'error' && toast.error(result.error.message);
			result.type === 'success' && toast.success(result.data?.message || 'Settings updated successfully');
		}
	});

	const { form: formData, enhance, submitting } = form;
</script>

<Button variant="outline" class="fixed right-4 top-4" onclick={() => (isOpen = true)}>
	<Lock class="mr-2 h-4 w-4" />
	Settings
</Button>

<Sheet.Root bind:open={isOpen}>
	<Sheet.Content class="w-[400px]">
		<Sheet.Header>
			<Sheet.Title>Settings</Sheet.Title>
			<Sheet.Description>Configure your members settings here.</Sheet.Description>
		</Sheet.Header>
		<form method="POST" action="?/updateSettings" use:enhance class="space-y-4 mt-4">
			<Form.Field {form} name="insuranceFormLink">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>HEMA Insurance Form Link</Form.Label>
						<Input
							{...props}
							type="url"
							bind:value={$formData.insuranceFormLink}
							placeholder="https://example.com/insurance-form"
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
			<Button type="submit" class="w-full" disabled={$submitting}>
				{#if $submitting}
					<LoaderCircle />
				{:else}
					Save Settings
				{/if}
			</Button>
		</form>
	</Sheet.Content>
</Sheet.Root>
