<script lang="ts">
import type { WaitlistStatus } from "@dhc/api-client";
import * as Select from "$lib/components/ui/select";

type Props = {
	status: WaitlistStatus;
	disabled?: boolean;
	onChange: (status: WaitlistStatus) => void;
};

const statuses = [
	"waiting",
	"invited",
	"paid",
	"deferred",
	"cancelled",
	"completed",
	"no_reply",
	"joined",
] as const satisfies readonly WaitlistStatus[];

let { status, disabled = false, onChange }: Props = $props();

function label(value: WaitlistStatus) {
	return value.replace("_", " ");
}
</script>

<Select.Root
	type="single"
	value={status}
	disabled={disabled}
	onValueChange={(value) => value && onChange(value as WaitlistStatus)}
>
	<Select.Trigger class="h-8 w-32 capitalize">
		{label(status)}
	</Select.Trigger>
	<Select.Content>
		{#each statuses as value (value)}
			<Select.Item {value} class="capitalize">{label(value)}</Select.Item>
		{/each}
	</Select.Content>
</Select.Root>
