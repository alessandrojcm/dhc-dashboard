<script lang="ts">
import { tick, untrack } from "svelte";
import * as Command from "$lib/components/ui/command/index.js";
import * as Popover from "$lib/components/ui/popover/index.js";
import { Button } from "$lib/components/ui/button/index.js";
import getUnicodeFlagIcon from "country-flag-icons/unicode";
import { Input } from "$lib/components/ui/input";
import * as countryCodesList from "country-codes-list";
import {
	AsYouType,
	isSupportedCountry,
	parsePhoneNumber,
	type CountryCode,
} from "libphonenumber-js/min";
import { parseIncompletePhoneNumber } from "libphonenumber-js";
import { ChevronDown, ChevronUp } from "@lucide/svelte";
import type { HTMLInputAttributes } from "svelte/elements";

const countryCodes = $state(countryCodesList.all());
let open = $state(false);
let triggerRef = $state<HTMLButtonElement>(null!);

let {
	value: initialValue = "",
	onChange,
	placeholder = "Enter your phone number",
	name,
	id,
	...props
}: Omit<HTMLInputAttributes, "value" | "files" | "type" | "bind:files"> & {
	value?: string | number;
	onChange?: (value: string) => void;
} = $props();

let countryValue = $state<CountryCode>("IE");
let formattedPhone = $state("");
let lastEmittedValue = $state("");

type ParsedPhoneNumber = {
	nationalNumber: string;
	value: CountryCode;
};

const defaultCountry: CountryCode = "IE";

function supportedCountry(countryCode: string): CountryCode {
	return isSupportedCountry(countryCode) ? countryCode : defaultCountry;
}

const nationalNumber = $derived(parseIncompletePhoneNumber(formattedPhone));

const selectedValue = $derived.by(() => {
	if (!countryValue) return null;
	return (
		countryCodesList.findOne("countryCode", countryValue)?.countryCallingCode ??
		null
	);
});

$effect(() => {
	const incomingValue = String(initialValue);
	if (incomingValue === untrack(() => lastEmittedValue)) return;

	const parsed = parseIncomingPhoneNumber(incomingValue);
	countryValue = parsed.value;
	formattedPhone = formatForDisplay(incomingValue, parsed);
});

function formatForDisplay(
	phoneNumber: string,
	parsed: ReturnType<typeof parseIncomingPhoneNumber>,
) {
	if (!phoneNumber) return "";

	if (phoneNumber.startsWith("+")) {
		try {
			return parsePhoneNumber(phoneNumber).formatNational();
		} catch {
			// Fall back to formatting the incomplete national number.
		}
	}

	return new AsYouType(parsed.value).input(parsed.nationalNumber);
}

// Parse an incoming phone number to extract country code and national number
function parseIncomingPhoneNumber(phoneNumber: string): ParsedPhoneNumber {
	if (!phoneNumber) {
		return { nationalNumber: "", value: defaultCountry };
	}
	// It is just a country code so return accordingly
	const isCountryCode = countryCodesList.findOne(
		"countryCallingCode",
		phoneNumber.replace("+", ""),
	);
	if (isCountryCode) {
		return {
			nationalNumber: "",
			value: supportedCountry(isCountryCode.countryCode),
		};
	}
	try {
		// If the number starts with '+', it's in international format
		if (phoneNumber.startsWith("+")) {
			const parsedNumber = parsePhoneNumber(phoneNumber);
			if (parsedNumber && parsedNumber.country) {
				return {
					value: parsedNumber.country,
					nationalNumber: parsedNumber.nationalNumber || "",
				};
			} else {
				return {
					value: defaultCountry,
					nationalNumber: phoneNumber.substring(1), // Remove the + sign
				};
			}
		} else {
			return {
				nationalNumber: phoneNumber,
				value: defaultCountry,
			};
		}
	} catch {
		// If parsing fails, just use the raw number
		return {
			nationalNumber: phoneNumber,
			value: defaultCountry,
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
	const formatter = new AsYouType(countryValue);
	formattedPhone = formatter.input(inputValue);
	const newPhoneNumber = formatter.getNumber()?.number ?? "";

	lastEmittedValue = newPhoneNumber;
	onChange?.(newPhoneNumber);
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
									countryValue = supportedCountry(country.countryCode);
									const formatter = new AsYouType(countryValue);
									formattedPhone = formatter.input(nationalNumber);
									const newPhoneNumber = formatter.getNumber()?.number ?? "";
									lastEmittedValue = newPhoneNumber;
									onChange?.(newPhoneNumber);
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
		{...props}
		{id}
		type="tel"
		bind:value={formattedPhone}
		oninput={(event) => {
			updatePhoneNumber(event.currentTarget.value);
		}}
		{placeholder}
	/>
	<input type="hidden" {name} {id} value={lastEmittedValue || initialValue} />
</div>
