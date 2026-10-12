/**
 * ALE-420: Beginners' Workshop copy never shows a backend term. Oxlint's
 * `anti-slop/no-backend-terms-in-copy` reads only `<script>`, so this test
 * scans the markup of every Beginners' Workshop `.svelte` file (script and
 * style removed) for the same phrases: visible text, attribute values and
 * string literals inside markup expressions.
 */
import { globSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { parse } from "svelte/compiler";
import type { AST } from "svelte/compiler";
import { describe, expect, it } from "vitest";

import {
	findBackendTerm,
	isMachineToken,
} from "../../../../../tools/oxlint/anti-slop/shared/backend-terms.ts";

const webRoot = join(import.meta.dirname, "../../..");

const BEGINNERS_WORKSHOP_SVELTE = [
	"src/routes/dashboard/beginners-workshop/**/*.svelte",
	"src/routes/dashboard/my-beginners-workshops/**/*.svelte",
	"src/routes/(public)/beginners/**/*.svelte",
	"src/lib/beginners-workshops/**/*.svelte",
	"src/lib/components/beginners-workshops/**/*.svelte",
	"src/lib/server/beginners-workshops/**/*.svelte",
];

type Finding = { offset: number; text: string; term: string };
type MarkupChild = AST.Fragment["nodes"][number];

const STRING_LITERAL = /(["'`])((?:\\.|(?!\1)[^\\])*)\1/gs;

/** Scans markup for copy: the fragment's text, attribute text and the string literals of every `{…}`. */
class MarkupScan {
	readonly findings: Finding[] = [];

	constructor(private readonly source: string) {}

	fragment(fragment: AST.Fragment | null | undefined): void {
		for (const node of fragment?.nodes ?? []) this.node(node);
	}

	private node(node: MarkupChild): void {
		switch (node.type) {
			case "Text":
				this.copy(node.start, node.data);
				return;
			case "Comment":
				return;
			case "IfBlock":
				this.literals(node.start, this.header(node.start));
				this.fragment(node.consequent);
				this.fragment(node.alternate);
				return;
			case "EachBlock":
				this.literals(node.start, this.header(node.start));
				this.fragment(node.body);
				this.fragment(node.fallback);
				return;
			case "AwaitBlock":
				this.literals(node.start, this.header(node.start));
				this.fragment(node.pending);
				this.fragment(node.then);
				this.fragment(node.catch);
				return;
			case "KeyBlock":
				this.literals(node.start, this.header(node.start));
				this.fragment(node.fragment);
				return;
			case "SnippetBlock":
				this.fragment(node.body);
				return;
			case "AttachTag":
			case "ConstTag":
			case "DeclarationTag":
			case "DebugTag":
			case "ExpressionTag":
			case "HtmlTag":
			case "RenderTag":
				this.literals(node.start, this.source.slice(node.start, node.end));
				return;
			default:
				this.element(node);
		}
	}

	private element(element: AST.ElementLike): void {
		for (const attribute of element.attributes) {
			if (attribute.type !== "Attribute") {
				this.literals(
					attribute.start,
					this.source.slice(attribute.start, attribute.end),
				);
				continue;
			}
			if (attribute.value === true) continue;
			const parts = Array.isArray(attribute.value)
				? attribute.value
				: [attribute.value];
			for (const part of parts) {
				if (part.type === "Text") {
					if (!isMachineToken(part.data)) this.copy(part.start, part.data);
				} else {
					this.literals(part.start, this.source.slice(part.start, part.end));
				}
			}
		}
		this.fragment(element.fragment);
	}

	/** A block's opening tag, `{#if …}`, up to its first closing brace. */
	private header(start: number): string {
		return this.source.slice(start, this.source.indexOf("}", start) + 1);
	}

	private literals(offset: number, expression: string): void {
		for (const match of expression.matchAll(STRING_LITERAL)) {
			// A template literal's `${…}` is code, not copy, as in the Oxlint rule.
			const text = (match[2] ?? "").replaceAll(/\$\{[^}]*\}/g, "");
			if (!isMachineToken(text)) this.copy(offset + (match.index ?? 0), text);
		}
	}

	private copy(offset: number, text: string): void {
		const term = findBackendTerm(text);
		if (term !== undefined)
			this.findings.push({ offset, text: text.trim(), term: term.term });
	}
}

function lineOf(source: string, offset: number): number {
	return source.slice(0, offset).split("\n").length;
}

describe("Beginners' Workshop copy vocabulary", () => {
	it("matches backend terms as whole phrases, case-insensitively", () => {
		expect(
			findBackendTerm("This person already has an open Intake")?.term,
		).toBe("Intake");
		expect(findBackendTerm("Their intakes stay in the reports")?.term).toBe(
			"Intake",
		);
		expect(findBackendTerm("Could not pause Batches")?.term).toBe("Batch");
		expect(findBackendTerm("You have a carried fee")?.term).toBe("Carried Fee");
		expect(findBackendTerm("Every seat is taken")?.term).toBe("seat");
		expect(findBackendTerm("The Seat Hold ends")?.term).toBe("Seat Hold");
		expect(findBackendTerm("Could not fast-track this person")?.term).toBe(
			"Fast-track",
		);
		expect(findBackendTerm("Waitlist entry updated.")?.term).toBe(
			"Waitlist entry",
		);
		expect(findBackendTerm("Pick a valid contact-from date.")?.term).toBe(
			"contact-from",
		);
		expect(findBackendTerm("Could not load the workshop console")?.term).toBe(
			"Console",
		);
		expect(findBackendTerm("Before Finalisation")?.term).toBe("Finalisation");
		expect(findBackendTerm("The Payment Cutoff must be before")?.term).toBe(
			"Payment Cutoff",
		);
	});

	it("leaves the copy vocabulary and words that only contain a term alone", () => {
		expect(
			findBackendTerm(
				"Their workshop place, offer round and workshop credit stay; the payment deadline passed.",
			),
		).toBeUndefined();
		expect(
			findBackendTerm("Seated together in the batched intakeroom"),
		).toBeUndefined();
	});

	it("treats snake_case values, ids and paths as machine tokens, not copy", () => {
		expect(isMachineToken("fast_track")).toBe(true);
		expect(isMachineToken("intake-row")).toBe(true);
		expect(isMachineToken("/beginners/intake/")).toBe(true);
		expect(isMachineToken("Intake")).toBe(false);
		expect(isMachineToken("an intake")).toBe(false);
	});

	it("shows no backend term in any Beginners' Workshop Svelte markup", () => {
		const files = BEGINNERS_WORKSHOP_SVELTE.flatMap((pattern) =>
			globSync(pattern, { cwd: webRoot }),
		);
		expect(files.length).toBeGreaterThan(20);

		const findings = files.flatMap((file) => {
			const source = readFileSync(join(webRoot, file), "utf8");
			const ast = parse(source, { modern: true });
			const scan = new MarkupScan(source);
			scan.fragment(ast.fragment);
			return scan.findings.map(
				({ offset, text, term }) =>
					`${relative(webRoot, join(webRoot, file))}:${lineOf(source, offset)} "${term}" in ${JSON.stringify(text)}`,
			);
		});

		expect(findings).toEqual([]);
	});
});
