/**
 * Pure helpers for the Member Emails composer (ADR 0028). Phoenix decides
 * whether a draft is valid; these only decide when the page bothers asking.
 */
import type { MemberAnnouncementDraft } from "@dhc/api-client";

/** Heading shown in the live preview until a subject is typed. */
export const PREVIEW_SUBJECT_FALLBACK = "Your subject";

type Node = { type?: string; text?: string; content?: Node[] };

/** Whether a Tiptap document contains any non-whitespace text. */
export function draftHasText(node: Node | undefined): boolean {
	if (!node) return false;
	if (node.type === "text") return (node.text ?? "").trim() !== "";
	return (node.content ?? []).some(draftHasText);
}

/** A stable key for "has the rendered output changed?". */
export function previewKey(draft: MemberAnnouncementDraft): string {
	return JSON.stringify([draft.subject, draft.includeInactive, draft.body]);
}
