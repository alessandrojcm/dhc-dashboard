<script lang="ts">
import * as countryCodesList from "country-codes-list";
import { parseIncompletePhoneNumber } from "libphonenumber-js";
import {
	AsYouType,
	type CountryCode,
	parsePhoneNumber,
} from "libphonenumber-js/min";
import { tick } from "svelte";

const _countryCodes = $state(countryCodesList.all());
let _open = $state(false);
const triggerRef = $state<HTMLButtonElement>(null!);

let {
	phoneNumber = $bindable(""),
	placeholder = "Enter your phone number",
	...props
}: {
	placeholder: string;
	phoneNumber: string;
	name: string;
	id: string;
	"data-fs-error": string | undefined;
	"aria-describedby": string | undefined;
	"aria-invalid": "true" | undefined;
	"aria-required": "true" | undefined;
	"data-fs-control": string;
} = $props();

let { nationalNumber, value } = $derived.by(() => {
	return parseIncomingPhoneNumber(phoneNumber);
});

const selectedValue = $derived.by(() => {
	if (!value) return null;
	return (
		countryCodesList.findOne("countryCode", value)?.countryCallingCode ?? null
	);
});

// Format the national number for display in the input field
const _formatedPhone = $derived.by(() => {
	if (!value) return new AsYouType().input(nationalNumber);
	return new AsYouType(value as CountryCode).input(nationalNumber);
});

// Parse an incoming phone number to extract country code and national number
function parseIncomingPhoneNumber(phoneNumber: string) {
	if (!phoneNumber) {
		return { nationalNumber: "", value: "IE" as CountryCode };
	}
	// It is just a country code so return accordingly
	const isCountryCode = countryCodesList.findOne(
		"countryCallingCode",
		phoneNumber.replace("+", ""),
	);
	if (isCountryCode) {
		return {
			nationalNumber: "",
			value: isCountryCode.countryCode,
		};
	}
	try {
		// If the number starts with '+', it's in international format
		if (phoneNumber.startsWith("+")) {
			const parsedNumber = parsePhoneNumber(phoneNumber);
			if (parsedNumber?.country) {
				return {
					value: parsedNumber.country,
					nationalNumber: parsedNumber.nationalNumber || "",
				};
			} else {
				return {
					value: "IE" as CountryCode,
					nationalNumber: phoneNumber.substring(1), // Remove the + sign
				};
			}
		} else {
			return {
				nationalNumber: phoneNumber,
				value: "IE" as CountryCode,
			};
		}
	} catch (_error) {
		// If parsing fails, just use the raw number
		return {
			nationalNumber: phoneNumber,
			value: "IE" as CountryCode,
		};
	}
}

// We want to refocus the trigger button when the user selects
// an item from the list so users can continue navigating the
// rest of the form with the keyboard.
function _closeAndFocusTrigger() {
	_open = false;
	tick().then(() => {
		triggerRef.focus();
	});
}

// Update the phone number when the input changes
function _updatePhoneNumber(inputValue: string) {
	// Parse the input to remove any formatting
	nationalNumber = parseIncompletePhoneNumber(inputValue);
	// Update the parent with the full international format
	if (selectedValue && nationalNumber) {
		phoneNumber = `+${selectedValue}${nationalNumber}`;
	} else if (nationalNumber) {
		phoneNumber = nationalNumber;
	} else {
		phoneNumber = "";
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
									phoneNumber = formatIncompletePhoneNumber(
										`+${country.countryCallingCode}${nationalNumber}`
									);
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
	<input type="hidden" {...props} bind:value={phoneNumber} />
</div>
