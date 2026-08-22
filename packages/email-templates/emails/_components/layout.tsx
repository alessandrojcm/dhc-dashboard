import type { ReactNode } from "react";

import { Body, Container, Html, Img, Preview, Section, Text } from "react-email";

export interface EmailLayoutProps {
  /** Rendered into the hidden `<Preview>` preheader. */
  preview?: string;
  /** Optional display heading under the logo (see {@link Heading}). */
  heading?: ReactNode;
  children: ReactNode;
}

/**
 * Brand colour tokens from the Dublin HEMA Club design system
 * (design-system/dublin-hema-club/MASTER.md). Hex values, because email
 * clients do not reliably support oklch()/hsl() custom properties.
 */
export const colors = {
  /** --color-primary (heritage navy) */
  primary: "#1f4f85",
  /** --color-on-primary */
  onPrimary: "#ffffff",
  /** --color-secondary / ring (brand gold) */
  secondary: "#e5b524",
  /** Pale gold used behind highlighted words in headings. */
  highlight: "#fbe7b1",
  /** --color-foreground (navy black) */
  foreground: "#121827",
  /** Near-white content surface */
  surface: "#fffdf8",
} as const;

/**
 * Club crest served by the `email dev` preview from `emails/static/`. The
 * template sync pipeline must rewrite this to its hosted absolute URL when
 * uploading to Resend — relative image sources break in email clients.
 */
export const LOGO_SRC = "/static/logo.png";

const body: React.CSSProperties = {
  backgroundColor: colors.surface,
  fontFamily:
    '"Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
  margin: 0,
};

/** Full-width brand-gold band behind the crest. */
const headerBand: React.CSSProperties = {
  backgroundColor: colors.secondary,
  height: "72px",
};

const container: React.CSSProperties = {
  margin: "0 auto",
  maxWidth: "600px",
  padding: "0 24px 32px",
};

const logo: React.CSSProperties = {
  borderRadius: "50%",
  display: "block",
  margin: "-48px auto 28px",
};

const text: React.CSSProperties = {
  color: colors.foreground,
  fontSize: "16px",
  lineHeight: "26px",
  margin: "0 0 20px",
};

/** Shared paragraph style so every template's body copy matches. */
export const paragraphStyle = text;

const headingStyle: React.CSSProperties = {
  color: colors.primary,
  fontFamily: '"Calistoga", Georgia, "Times New Roman", serif',
  fontSize: "32px",
  lineHeight: "42px",
  margin: "0 0 32px",
  textAlign: "center",
};

/** Link styling in the heritage navy every CTA uses. */
export const linkStyle: React.CSSProperties = {
  color: colors.primary,
};

/** Primary button matching the design system's `.btn-primary`. */
export const buttonStyle: React.CSSProperties = {
  backgroundColor: colors.primary,
  borderRadius: "8px",
  color: colors.onPrimary,
  display: "inline-block",
  fontSize: "16px",
  fontWeight: 600,
  margin: "0 0 20px",
  padding: "12px 24px",
  textDecoration: "none",
};

/** Pale-gold marker for words inside a {@link Heading}, like the mockup. */
export function Mark({ children }: { children: ReactNode }) {
  return <span style={{ backgroundColor: colors.highlight }}>{children}</span>;
}

export function Heading({ children }: { children: ReactNode }) {
  return <Text style={headingStyle}>{children}</Text>;
}

/**
 * Shared shell for all DHC transactional emails: a full-width gold band
 * with the club crest overlapping into a plain near-white content column —
 * matching the club's brand mockup.
 *
 * Lives in an underscore-prefixed folder so the `email dev` preview does
 * not list it as a template.
 */
export function EmailLayout({ preview = "Dublin HEMA Club", heading, children }: EmailLayoutProps) {
  return (
    <Html lang="en">
      <Preview>{preview}</Preview>
      <Body style={body}>
        <Section style={headerBand} role="presentation" />
        <Container style={container}>
          <Img alt="Dublin HEMA Club" height={96} src={LOGO_SRC} style={logo} width={96} />
          {heading ? <Heading>{heading}</Heading> : null}
          {children}
        </Container>
      </Body>
    </Html>
  );
}

interface SignOffProps {
  /** Closing word; the original Loops templates use "Regards" or "Best". */
  close?: string;
}

/** Renders the club sign-off block ("Regards,\nDublin HEMA Club"). */
export function SignOff({ close = "Regards" }: SignOffProps) {
  return (
    <Text style={{ ...text, whiteSpace: "pre-line", marginBottom: 0 }}>
      {close}
      {"\n"}Dublin HEMA Club
    </Text>
  );
}
