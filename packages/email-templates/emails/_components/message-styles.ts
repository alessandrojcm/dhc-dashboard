import { colors } from "./layout";

/**
 * Inline styles for the rich-text vocabulary of a Member Announcement body
 * (ADR 0028). Email clients ignore most `<style>` blocks, so Phoenix writes
 * these declarations onto every element it renders from the Tiptap document.
 *
 * This record is the one source of those styles: `scripts/render-shells.tsx`
 * exports it next to the shell HTML for Phoenix
 * (`apps/phoenix/priv/email_shells/member-announcement.styles.json`), and
 * the `email dev` preview sample uses it too. Values are plain CSS
 * declaration strings so nothing has to translate React style objects.
 */
export const MESSAGE_STYLES = {
  p: `color:${colors.foreground};font-size:16px;line-height:26px;margin:0 0 20px`,
  h2: `color:${colors.primary};font-family:"Calistoga",Georgia,"Times New Roman",serif;font-size:24px;line-height:32px;margin:28px 0 12px`,
  h3: `color:${colors.primary};font-size:18px;font-weight:700;line-height:26px;margin:24px 0 8px`,
  ul: `color:${colors.foreground};font-size:16px;line-height:26px;margin:0 0 20px;padding-left:24px`,
  ol: `color:${colors.foreground};font-size:16px;line-height:26px;margin:0 0 20px;padding-left:24px`,
  li: "margin:0 0 6px",
  blockquote: `border-left:4px solid ${colors.secondary};color:${colors.foreground};margin:0 0 20px;padding:4px 0 4px 16px`,
  a: `color:${colors.primary};text-decoration:underline`,
  hr: "border:none;border-top:1px solid #e5e7eb;margin:28px 0",
  strong: "font-weight:700",
  em: "font-style:italic",
  u: "text-decoration:underline",
  s: "text-decoration:line-through",
} as const satisfies Record<string, string>;

export type MessageElement = keyof typeof MESSAGE_STYLES;
