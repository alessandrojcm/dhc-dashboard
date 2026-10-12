import { spawn } from "node:child_process";
import { once } from "node:events";
import { test, expect, vi } from "vitest";
import { intakeSafeLogger } from "./intake-safe-logger.js";

test("redacting a warning preserves Vite's warning flag", () => {
	const sink = vi.spyOn(console, "warn").mockImplementation(() => {});
	try {
		const logger = intakeSafeLogger();
		logger.warn("GET /beginners/intake/private-warning-credential");
		expect(logger.hasWarned).toBe(true);
		expect(sink).toHaveBeenCalledWith(
			expect.stringContaining("/beginners/intake/[REDACTED]"),
		);
	} finally {
		sink.mockRestore();
	}
});

test("SvelteKit access logs retain the request but not the Intake credential", async () => {
	const token = "access-log-private-intake-credential";
	const child = spawn(
		process.execPath,
		[
			"node_modules/vite/bin/vite.js",
			"dev",
			"--host",
			"127.0.0.1",
			"--port",
			"0",
		],
		{
			cwd: process.cwd(),
			env: { ...process.env, E2E_SERVER: "true", NO_COLOR: "1" },
			stdio: ["ignore", "pipe", "pipe"],
		},
	);
	let output = "";
	const capture = (chunk: Buffer) => {
		output += chunk.toString();
	};
	child.stdout.on("data", capture);
	child.stderr.on("data", capture);
	const waitFor = (pattern: RegExp) =>
		new Promise<void>((resolve, reject) => {
			const cleanup = () => {
				clearTimeout(timer);
				child.stdout.off("data", check);
				child.stderr.off("data", check);
				child.off("exit", stopped);
			};
			const check = () => {
				if (pattern.test(output)) {
					cleanup();
					resolve();
				}
			};
			const stopped = () => {
				cleanup();
				reject(new Error("Vite exited before request logs were emitted"));
			};
			const timer = setTimeout(() => {
				cleanup();
				reject(new Error("Timed out awaiting Vite request logs"));
			}, 45000);
			child.stdout.on("data", check);
			child.stderr.on("data", check);
			child.on("exit", stopped);
			check();
		});
	try {
		await waitFor(/http:\/\/127\.0\.0\.1:\d+/);
		const origin = output.match(/http:\/\/127\.0\.0\.1:\d+/)![0];
		const response = await fetch(
			`${origin}/beginners/intake/${token}?probe=access-log`,
			{ signal: AbortSignal.timeout(15000) },
		);
		await response.text();
		await waitFor(/GET.*beginners\/intake/);
		expect(output).toMatch(/\d{3} GET.*beginners\/intake\/\[REDACTED\]/);
		expect(output).not.toContain(token);
	} finally {
		if (child.exitCode === null && child.signalCode === null) {
			const exited = once(child, "exit");
			child.kill("SIGTERM");
			await exited;
		}
	}
}, 65000);
