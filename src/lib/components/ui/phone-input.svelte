<script lang="ts">
	import { tick } from 'svelte';
	import * as Command from '$lib/components/ui/command/index.js';
	import * as Popover from '$lib/components/ui/popover/index.js';
	import { Button } from '$lib/components/ui/button/index.js';
	import getUnicodeFlagIcon from 'country-flag-icons/unicode';
	import { Input } from '$lib/components/ui/input';
	import * as countryCodesList from 'country-codes-list';
	import {
		AsYouType,
		parsePhoneNumber,
		type CountryCode,
		formatIncompletePhoneNumber
	} from 'libphonenumber-js/min';
	import { parseIncompletePhoneNumber } from 'libphonenumber-js';
	import { ChevronDown, ChevronUp } from 'lucide-svelte';


	const countryCodes = $state(countryCodesList.all());
	let open = $state(false);
	let triggerRef = $state<HTMLButtonElement>(null!);

	let {
		value: initialValue = '',
		onChange,
		placeholder = 'Enter your phone number',
		name,
		id,
		...props
	}: {
		placeholder?: string;
		value?: string | number;
		onChange?: (value: string) => void;
		name?: string;
		id?: string;
	} = $props();

	// Internal state for the phone number value - synced with initialValue
	let phoneNumber = $derived(String(initialValue));

	let { nationalNumber, value: countryValue } = $derived.by(() => {
		return parseIncomingPhoneNumber(phoneNumber);
	});

	const selectedValue = $derived.by(() => {
		if (!countryValue) return null;
		return countryCodesList.findOne('countryCode', countryValue)?.countryCallingCode ?? null;
	});

	// Format the national number for display in the input field
	const formatedPhone = $derived.by(() => {
		if (!countryValue) return new AsYouType().input(nationalNumber);
		return new AsYouType(countryValue as CountryCode).input(nationalNumber);
	});

	// Parse an incoming phone number to extract country code and national number
	function parseIncomingPhoneNumber(phoneNumber: string) {
		if (!phoneNumber) {
			return { nationalNumber: '', value: 'IE' as CountryCode };
		}
		// It is just a country code so return accordingly
		const isCountryCode = countryCodesList.findOne(
			'countryCallingCode',
			phoneNumber.replace('+', '')
		);
		if (isCountryCode) {
			return {
				nationalNumber: '',
				value: isCountryCode.countryCode
			};
		}
		try {
			// If the number starts with '+', it's in international format
			if (phoneNumber.startsWith('+')) {
				const parsedNumber = parsePhoneNumber(phoneNumber);
				if (parsedNumber && parsedNumber.country) {
					return {
						value: parsedNumber.country,
						nationalNumber: parsedNumber.nationalNumber || ''
					};
				} else {
					return {
						value: 'IE' as CountryCode,
						nationalNumber: phoneNumber.substring(1) // Remove the + sign
					};
				}
			} else {
				return {
					nationalNumber: phoneNumber,
					value: 'IE' as CountryCode
				};
			}
		} catch {
			// If parsing fails, just use the raw number
			return {
				nationalNumber: phoneNumber,
				value: 'IE' as CountryCode
			};
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
		let newPhoneNumber = '';
		if (selectedValue && nationalNumber) {
			newPhoneNumber = `+${selectedValue}${nationalNumber}`;
		} else if (nationalNumber) {
			newPhoneNumber = nationalNumber;
		}
		if (onChange) {
			onChange(newPhoneNumber);
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
						{`${getUnicodeFlagIcon(countryValue)} +${selectedValue}`}
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
						{#each countryCodes as country (country.countryNameEn)}
							<Command.Item
								value={country.countryNameEn}
								onSelect={() => {
									const newPhoneNumber = formatIncompletePhoneNumber(
										`+${country.countryCallingCode}${nationalNumber}`
									);
									if (onChange) {
										onChange(newPhoneNumber);
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
		value={formatedPhone}
		onchange={(event: Event) => {
			if (!event.target) return;
			updatePhoneNumber((event.target as HTMLInputElement).value);
		}}
		{placeholder}
	/>
	<input type="hidden" {name} {id} value={phoneNumber} />
</div>
