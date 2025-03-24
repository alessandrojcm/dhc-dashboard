<script lang="ts">
	import { tick } from 'svelte';
	import * as Command from '$lib/components/ui/command/index.js';
	import * as Popover from '$lib/components/ui/popover/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import getUnicodeFlagIcon from 'country-flag-icons/unicode';
	import { Input } from '$lib/components/ui/input';
	import * as countryCodesList from 'country-codes-list';
	import { AsYouType, parsePhoneNumber, type CountryCode } from 'libphonenumber-js/min';
	import { parseIncompletePhoneNumber } from 'libphonenumber-js';
	import { ChevronDown, ChevronUp } from 'lucide-svelte';

	const countryCodes = $state(countryCodesList.all());
	let open = $state(false);
	let value = $state('IE'); // Default country code
	let triggerRef = $state<HTMLButtonElement>(null!);
	let nationalNumber = $state(''); // Store the national number without country code

	const selectedValue = $derived.by(() => {
		return countryCodesList.findOne('countryCode', value ?? 'IE')?.countryCallingCode ?? null;
	});

	let {
		phoneNumber = $bindable(''),
		placeholder = 'Enter your phone number',
		...props
	}: {
		placeholder: string;
		phoneNumber: string;
		name: string;
		id: string;
		'data-fs-error': string | undefined;
		'aria-describedby': string | undefined;
		'aria-invalid': 'true' | undefined;
		'aria-required': 'true' | undefined;
		'data-fs-control': string;
	} = $props();

	// Parse the incoming phone number when the component mounts or phoneNumber changes
	$effect(() => {
		parseIncomingPhoneNumber();
	});

	// Format the national number for display in the input field
	const formatedPhone = $derived.by(() => {
		return new AsYouType((value as CountryCode) ?? 'IE').input(nationalNumber);
	});

	// Parse an incoming phone number to extract country code and national number
	function parseIncomingPhoneNumber() {
		if (!phoneNumber) {
			nationalNumber = '';
			return;
		}

		try {
			// If the number starts with '+', it's in international format
			if (phoneNumber.startsWith('+')) {
				const parsedNumber = parsePhoneNumber(phoneNumber);
				if (parsedNumber && parsedNumber.country) {
					// Update the country code dropdown
					value = parsedNumber.country;
					// Set the national number without the country code
					nationalNumber = parsedNumber.nationalNumber || '';
				} else {
					// If parsing fails, treat the whole thing as a national number
					nationalNumber = phoneNumber.substring(1); // Remove the + sign
				}
			} else {
				// If not in international format, use as is
				nationalNumber = phoneNumber;
			}
		} catch (error) {
			// If parsing fails, just use the raw number
			nationalNumber = phoneNumber;
		}
	}

	// We want to refocus the trigger button when the user selects
	// an item from the list so users can continue navigating the
	// rest of the form with the keyboard.
	function closeAndFocusTrigger() {
		open = false;
		tick().then(() => {
			triggerRef.focus();
		});
	}

	// Update the phone number when the input changes
	function updatePhoneNumber(inputValue: string) {
		// Parse the input to remove any formatting
		nationalNumber = parseIncompletePhoneNumber(inputValue);

		// Update the parent with the full international format
		if (selectedValue && nationalNumber) {
			phoneNumber = `+${selectedValue}${nationalNumber}`;
		} else if (nationalNumber) {
			phoneNumber = nationalNumber;
		} else {
			phoneNumber = '';
		}
	}
</script>

<div class="flex gap-2">
	<Popover.Root bind:open>
		<Popover.Trigger bind:ref={triggerRef}>
			{#snippet child({ props })}
				<Button
					aria-label="Country code"
					variant="outline"
					class="w-[16ch] justify-between"
					{...props}
					role="combobox"
					aria-expanded={open}
				>
					{#if open}
						<ChevronUp class="h-4 w-4" />
					{:else}
						<ChevronDown class="h-4 w-4" />
					{/if}
					{#if selectedValue}
						{`${getUnicodeFlagIcon(value)} +${selectedValue}`}
					{:else}
						Select a country...
					{/if}
				</Button>
			{/snippet}
		</Popover.Trigger>
		<Popover.Content class="w-[200px] p-0">
			<Command.Root>
				<Command.Input placeholder="Search country..." />
				<Command.List>
					<Command.Empty>No country found.</Command.Empty>
					<Command.Group>
						{#each countryCodes as country}
							<Command.Item
								value={country.countryNameEn}
								onSelect={() => {
									value = country.countryCode;
									// Update the parent with the new country code
									if (nationalNumber) {
										phoneNumber = `+${country.countryCallingCode}${nationalNumber}`;
									}
									closeAndFocusTrigger();
								}}
							>
								{getUnicodeFlagIcon(country.countryCode)}
								&nbsp;+{country.countryCallingCode}
							</Command.Item>
						{/each}
					</Command.Group>
				</Command.List>
			</Command.Root>
		</Popover.Content>
	</Popover.Root>
	<Input
		type="tel"
		{...props}
		value={formatedPhone}
		onchange={(event) => {
			if (!event.target) return;
			updatePhoneNumber(event.target.value);
		}}
		{placeholder}
	/>
</div>
