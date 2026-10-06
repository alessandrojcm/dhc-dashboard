import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { render } from "vitest-browser-svelte";
import RoleEditor from "./role-editor.svelte";

function props() {
	return {
		roles: ["member"] as const,
		availableRoles: ["member", "coach", "admin", "president"] as const,
		onSave: vi.fn(),
		onReload: vi.fn(),
	};
}

test("shows current roles and saves additions/removals only on an explicit click", async () => {
	const p = props();
	const screen = await render(RoleEditor, {
		...p,
		roles: [...p.roles],
		availableRoles: [...p.availableRoles],
	});
	const save = screen.getByRole("button", { name: "Save roles" });
	await expect
		.element(screen.getByRole("checkbox", { name: "member", exact: true }))
		.toHaveAttribute("aria-checked", "true");
	await expect.element(save).toBeDisabled();
	await userEvent.click(
		screen.getByRole("checkbox", { name: "coach", exact: true }),
	);
	await userEvent.click(
		screen.getByRole("checkbox", { name: "member", exact: true }),
	);
	expect(p.onSave).not.toHaveBeenCalled();
	await userEvent.click(save);
	expect(p.onSave).toHaveBeenCalledWith(["coach"]);
	await expect
		.element(screen.getByText(/signs this member out on all devices/))
		.toBeVisible();
});

test("reset discards the draft without saving", async () => {
	const p = props();
	const screen = await render(RoleEditor, {
		...p,
		roles: [...p.roles],
		availableRoles: [...p.availableRoles],
	});
	await userEvent.click(
		screen.getByRole("checkbox", { name: "admin", exact: true }),
	);
	await userEvent.click(screen.getByRole("button", { name: "Reset" }));
	await expect
		.element(screen.getByRole("checkbox", { name: "admin", exact: true }))
		.toHaveAttribute("aria-checked", "false");
	await expect
		.element(screen.getByRole("button", { name: "Save roles" }))
		.toBeDisabled();
	expect(p.onSave).not.toHaveBeenCalled();
});

test("pending disables changes and warns when editing yourself", async () => {
	const p = props();
	const screen = await render(RoleEditor, {
		...p,
		roles: [...p.roles],
		availableRoles: [...p.availableRoles],
		pending: true,
		isOwnProfile: true,
	});
	await expect
		.element(screen.getByRole("button", { name: "Saving roles…" }))
		.toBeDisabled();
	await expect
		.element(screen.getByRole("checkbox", { name: "coach", exact: true }))
		.toBeDisabled();
	await expect
		.element(screen.getByText(/editing your own roles/))
		.toBeVisible();
});

test("stale saves show the server error and require reloading", async () => {
	const p = props();
	const screen = await render(RoleEditor, {
		...p,
		roles: [...p.roles],
		availableRoles: [...p.availableRoles],
		stale: true,
		error: "Roles changed. Reload before saving.",
	});
	await expect
		.element(screen.getByRole("alert"))
		.toHaveTextContent("Roles changed. Reload before saving.");
	await expect
		.element(screen.getByRole("button", { name: "Save roles" }))
		.toBeDisabled();
	await userEvent.click(screen.getByRole("button", { name: "Reload roles" }));
	expect(p.onReload).toHaveBeenCalledTimes(1);
	expect(p.onSave).not.toHaveBeenCalled();
});
