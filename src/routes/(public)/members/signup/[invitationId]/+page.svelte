<script lang="ts">
import ConfirmInvitation from './confirm-invitation.svelte';
import PaymentForm from './payment-form.svelte';

const { data } = $props();
let isVerified = $derived(data.isConfirmed);
</script>

{#if !isVerified}
	<ConfirmInvitation bind:isVerified={isVerified} />
{:else}
	<PaymentForm {data} />
{/if}
