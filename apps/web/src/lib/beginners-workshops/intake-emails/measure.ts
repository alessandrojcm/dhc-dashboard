/**
 * The Intake Email template counter (ALE-383): the browser twin of Phoenix's
 * save check (`Dhc.BeginnersWorkshops.IntakeEmails.Renderer.measure/2`).
 *
 * The body renders the way `Dhc.Email.RichText` renders it without inline
 * styles, with every placeholder replaced by the filler repeated to its
 * maximum length, and the result is counted in UTF-16 code units
 * (`String#length`). The limit, filler and maxima come from the fixture file
 * Phoenix tests itself against, and this module's tests run the same
 * fixture cases, so the counter and the save check cannot disagree.
 */
import {
	filler,
	limit,
	maxima,
} from "@dhc/email-templates/fixtures/intake-email-measure.json";
import type { IntakeEmailPlaceholder } from "@dhc/api-client";

/** Resend's per-variable limit, which a saved body must fit. */
export const INTAKE_EMAIL_LIMIT: number = limit;

type Mark = { type: string; attrs?: { href?: string } };

/**
 * A Tiptap JSON node, as `editor.getJSON()` produces it, with the attributes
 * the template vocabulary uses.
 */
export type IntakeEmailNode = {
	type?: string;
	text?: string;
	attrs?: { name?: string; level?: number; start?: number };
	marks?: Mark[];
	content?: IntakeEmailNode[];
};

export type IntakeEmailMeasure = {
	/** The worst-case HTML Phoenix would put in `MESSAGE_HTML`. */
	html: string;
	/** Its length in UTF-16 code units. */
	length: number;
	fits: boolean;
	/** Phoenix refuses a body with no visible text. */
	hasText: boolean;
	/** Placeholders in the body the email type can't fill, in order. */
	refused: string[];
};

const MAXIMA = new Map(Object.entries(maxima));

const MARK_TAGS = new Map([
	["bold", "strong"],
	["italic", "em"],
	["underline", "u"],
	["strike", "s"],
]);

/** HTML-escapes text exactly like `Dhc.Email.RichText.escape/1`. */
export function escapeHtml(text: string): string {
	return text.replace(/[&<>"']/g, (char) => {
		switch (char) {
			case "&":
				return "&amp;";
			case "<":
				return "&lt;";
			case ">":
				return "&gt;";
			case '"':
				return "&quot;";
			default:
				return "&#39;";
		}
	});
}

function marked(text: string, marks: Mark[] | undefined): string {
	let html = escapeHtml(text);
	for (const mark of marks ?? []) {
		if (mark.type === "link") {
			const escaped = escapeHtml(mark.attrs?.href ?? "");
			html = `<a href="${escaped}" target="_blank" rel="noopener noreferrer">${html}</a>`;
		} else {
			const tag = MARK_TAGS.get(mark.type);
			if (tag) html = `<${tag}>${html}</${tag}>`;
		}
	}
	return html;
}

type Rendered = { html: string; visible: boolean };

function inline(nodes: IntakeEmailNode[] | undefined, names: string[]) {
	let html = "";
	let visible = false;
	for (const node of nodes ?? []) {
		if (node.type === "text") {
			const text = node.text ?? "";
			html += marked(text, node.marks);
			visible ||= text.trim() !== "";
		} else if (node.type === "hardBreak") {
			html += "<br>";
		} else if (node.type === "placeholder") {
			const name = node.attrs?.name ?? "";
			names.push(name);
			const value = filler.repeat(MAXIMA.get(name) ?? 0);
			html += marked(value, node.marks);
			visible ||= value !== "";
		}
	}
	return { html, visible };
}

function blocks(nodes: IntakeEmailNode[] | undefined, names: string[]) {
	const rendered = (nodes ?? []).map((node) => block(node, names));
	return {
		html: rendered.map((child) => child.html).join(""),
		visible: rendered.some((child) => child.visible),
	};
}

// Lists, quotes and rules always contribute text to Phoenix's plain-text
// part (a bullet, a number, "> ", "———"), so they count as visible.
function block(node: IntakeEmailNode, names: string[]): Rendered {
	switch (node.type) {
		case "paragraph": {
			const { html, visible } = inline(node.content, names);
			return { html: `<p>${html === "" ? "<br>" : html}</p>`, visible };
		}
		case "heading": {
			const level = node.attrs?.level === 3 ? 3 : 2;
			const { html, visible } = inline(node.content, names);
			return { html: `<h${level}>${html}</h${level}>`, visible };
		}
		case "bulletList":
			return { html: `<ul>${items(node, names)}</ul>`, visible: true };
		case "orderedList": {
			const start = node.attrs?.start ?? 1;
			const attr =
				Number.isInteger(start) && start >= 0 && start !== 1
					? ` start="${start}"`
					: "";
			return { html: `<ol${attr}>${items(node, names)}</ol>`, visible: true };
		}
		case "blockquote":
			return {
				html: `<blockquote>${blocks(node.content, names).html}</blockquote>`,
				visible: true,
			};
		case "horizontalRule":
			return { html: "<hr>", visible: true };
		default:
			return blocks(node.content, names);
	}
}

function items(list: IntakeEmailNode, names: string[]): string {
	return (list.content ?? [])
		.map((item) => `<li>${blocks(item.content, names).html}</li>`)
		.join("");
}

/**
 * Measures a template body for an email type that can fill `allowed`.
 */
export function measureIntakeEmail(
	body: IntakeEmailNode,
	allowed: readonly IntakeEmailPlaceholder[],
): IntakeEmailMeasure {
	const names: string[] = [];
	const { html, visible } = blocks(body.content, names);
	const allowedNames: readonly string[] = allowed;
	const refused = [...new Set(names)].filter(
		(name) => !allowedNames.includes(name),
	);
	return {
		html,
		length: html.length,
		fits: html.length <= INTAKE_EMAIL_LIMIT,
		hasText: visible,
		refused,
	};
}

const SUBJECT_TOKEN = /\{\{(.*?)\}\}/g;

/** `{{name}}` tokens in a subject the email type can't fill, in order. */
export function refusedSubjectTokens(
	subject: string,
	allowed: readonly IntakeEmailPlaceholder[],
): string[] {
	const allowedNames: readonly string[] = allowed;
	const names = [...subject.matchAll(SUBJECT_TOKEN)].map(
		(match) => match[1] ?? "",
	);
	return [...new Set(names)].filter((name) => !allowedNames.includes(name));
}
