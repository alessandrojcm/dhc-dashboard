<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { superForm } from 'sveltekit-superforms';
	import * as Card from '$lib/components/ui/card';
	import DatePicker from '$lib/components/ui/date-picker.svelte';

	const form = superForm({});
	const handleFormSubmit = (event: Event) => {
		event.preventDefault();
		console.log('Form Data:', form);
		// Perform form submission or any necessary validation here
	};
</script>

<svelte:head>
	<title>Dublin Hema Club - Waitlist Registration</title>
</svelte:head>
<Card.Root class="self-center w-96 mt-[15%]">
	<Card.Header>
		<Card.Title class="prose prose-h1 text-xl">Waitlist Form</Card.Title>
		<Card.Description class="prose">
			Thanks for your interest in Dublin Hema Club! Please sign up for our waitlist, we will contact
			you once a spot for our beginners workshop opens</Card.Description
		>
	</Card.Header>
	<Card.Content>
		<form on:submit={handleFormSubmit} class="flex flex-col gap-4 items-stretch">
			<Form.Field {form} name="firstName">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>First Name</Form.Label>
						<Input {...props} bind:value={form.firstName} placeholder="Enter your first name" />
					{/snippet}
				</Form.Control>
			</Form.Field>

			<Form.Field {form} name="lastName">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Last Name</Form.Label>
						<Input {...props} bind:value={form.lastName} placeholder="Enter your last name" />
					{/snippet}
				</Form.Control>
			</Form.Field>

			<Form.Field {form} name="email">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Email</Form.Label>
						<Input type="email" {...props} bind:value={form.email} placeholder="Enter your email" />
					{/snippet}
				</Form.Control>
			</Form.Field>

			<Form.Field {form} name="phoneNumber">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Phone Number</Form.Label>
						<Input
							type="tel"
							{...props}
							bind:value={form.phoneNumber}
							placeholder="Enter your phone number"
						/>
					{/snippet}
				</Form.Control>
			</Form.Field>

			<Form.Field {form} name="dateOfBirth">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Date of Birth</Form.Label>
						<DatePicker />
					{/snippet}
				</Form.Control>
			</Form.Field>

			<Form.Field {form} name="medicalCondition">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label>Any Medical Condition</Form.Label>
						<Input
							type="textarea"
							{...props}
							bind:value={form.medicalCondition}
							placeholder="Enter any medical conditions"
						/>
					{/snippet}
				</Form.Control>
			</Form.Field>

			<Button type="submit">Submit</Button>
		</form>
	</Card.Content>
</Card.Root>
