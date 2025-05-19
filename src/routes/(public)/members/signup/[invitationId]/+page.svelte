<script lang="ts">
	import PaymentForm from './payment-form.svelte';
	import ConfirmInvitation from './confirm-invitation.svelte';

	const { data } = $props();
	let isVerified = $state(data.isConfirmed);

</script>

{#if !isVerified}
	<ConfirmInvitation bind:isVerified />
{:else}
	<PaymentForm {...data} />
{/if}
