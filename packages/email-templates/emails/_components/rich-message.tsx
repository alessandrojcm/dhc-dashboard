import { MESSAGE_STYLES } from "./message-styles";
import { colors } from "./layout";

/**
 * Class on the wrapper of a rich-text body that Phoenix renders **without
 * per-element inline styles** (the Beginners' Workshop Intake Emails, ALE-377).
 *
 * Such a body travels through one Resend template variable, which Resend caps
 * at 2,000 characters; inline styles on every element would spend most of
 * that budget on markup. The template therefore styles the body instead:
 * inherited typography on the wrapper (which every client honours) plus a
 * `<style>` block scoped to this class for element spacing, built from the
 * same `MESSAGE_STYLES` table Member Announcements inline.
 */
export const RICH_MESSAGE_CLASS = "dhc-message";

/** Typography the body inherits even where `<style>` blocks are stripped. */
export const richMessageWrapperStyle: React.CSSProperties = {
  color: colors.foreground,
  fontSize: "16px",
  lineHeight: "26px",
};

/** The scoped stylesheet for {@link RichMessage}; one rule per vocabulary element. */
export function richMessageCss(): string {
  return Object.entries(MESSAGE_STYLES)
    .map(([tag, declarations]) => `.${RICH_MESSAGE_CLASS} ${tag}{${declarations}}`)
    .concat(`.${RICH_MESSAGE_CLASS} li p{margin:0}`)
    .join("\n");
}

/**
 * Renders already-safe body HTML (Phoenix escapes every text node and
 * placeholder value) into the styled wrapper.
 */
export function RichMessage({ html }: { html: string }) {
  return (
    <div
      className={RICH_MESSAGE_CLASS}
      style={richMessageWrapperStyle}
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
