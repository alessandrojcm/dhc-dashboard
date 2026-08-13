<script lang="ts">
import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";
const { children } = $props();
</script>

<svelte:head>
	<title>Dublin Hema Club - Login</title>
</svelte:head>

<div class="auth-shell">
	<div class="club-panel">
		<div class="club-panel__content">
			<div class="club-panel__logo">
				<enhanced:img src={DHCLogo} alt="Dublin Hema Club Logo" />
			</div>
			<p class="club-panel__eyebrow">Historical European Martial Arts</p>
			<h1>Your club, in reach.</h1>
			<p class="club-panel__copy">
				Sign in to manage your training, workshops, equipment, and the wider
				club.
			</p>
		</div>
		<p class="club-panel__footer">Dublin Hema Club · Member portal</p>
	</div>
	<div class="auth-content">
		{@render children()}
	</div>
</div>

<style>
.auth-shell {
	display: flex;
	min-height: 100dvh;
}
.club-panel {
	display: none;
	position: relative;
	flex: 0 0 38%;
	min-height: 100dvh;
	overflow: hidden;
	background: hsl(var(--primary));
	color: hsl(var(--primary-foreground));
}
.club-panel::after {
	position: absolute;
	inset: auto -7rem -8rem auto;
	width: 21rem;
	height: 21rem;
	border: 1px solid hsl(var(--secondary) / 0.6);
	border-radius: 999px;
	box-shadow:
		0 0 0 2.5rem hsl(var(--secondary) / 0.1),
		0 0 0 5rem hsl(var(--secondary) / 0.06);
	content: "";
}
.club-panel__content {
	position: relative;
	z-index: 1;
	max-width: 27rem;
	padding: 3rem;
}
.club-panel__logo {
	display: grid;
	width: 4rem;
	height: 4rem;
	place-items: center;
	margin-bottom: 5rem;
	border: 1px solid hsl(var(--secondary) / 0.7);
	border-radius: 0.75rem;
	background: hsl(var(--primary-foreground));
	padding: 0.5rem;
}
.club-panel__logo :global(img) {
	max-width: 100%;
	max-height: 100%;
	object-fit: contain;
}
.club-panel__eyebrow {
	margin: 0 0 0.75rem;
	color: hsl(var(--secondary));
	font-size: 0.6875rem;
	font-weight: 800;
	letter-spacing: 0.14em;
	text-transform: uppercase;
}
h1 {
	margin: 0;
	font-family: Georgia, "Times New Roman", serif;
	font-size: clamp(2.3rem, 4vw, 4.5rem);
	letter-spacing: -0.05em;
	line-height: 0.96;
}
.club-panel__copy {
	max-width: 24rem;
	margin: 1.5rem 0 0;
	color: hsl(var(--primary-foreground) / 0.72);
	line-height: 1.65;
}
.club-panel__footer {
	position: absolute;
	bottom: 2rem;
	left: 3rem;
	margin: 0;
	color: hsl(var(--primary-foreground) / 0.55);
	font-size: 0.75rem;
}
.auth-content {
	display: flex;
	flex: 1;
	align-items: center;
	justify-content: center;
	padding: 1.5rem;
}
@media (min-width: 768px) {
	.club-panel {
		display: block;
	}
	.auth-content {
		padding: 2.5rem;
	}
}
</style>
