import { defineRule } from "@oxlint/plugins";

const CLUB_TIME_ZONE = "Europe/Dublin";

/** The one module that names the zone, plus tests and throwaway prototypes. */
function mayNameZone(filename: string): boolean {
  const path = filename.replaceAll("\\", "/");
  return (
    path.endsWith("/src/lib/club-calendar.ts") ||
    /\.(test|spec)\.[cm]?[jt]sx?$/.test(path) ||
    /\/routes\/(.+\/)?prototype\//.test(path)
  );
}

/**
 * Keep the Club Calendar's zone in `apps/web/src/lib/club-calendar.ts`, so no
 * context formats Dublin dates and times with its own copy.
 */
export const noDublinTimeZoneLiteralRule = defineRule({
  meta: {
    type: "problem",
    docs: {
      description:
        'Disallow the "Europe/Dublin" literal outside src/lib/club-calendar.ts; import the Club Calendar instead.',
    },
    messages: {
      dublinTimeZoneLiteral:
        'Import the Dublin date or time helper you need from `#lib/club-calendar.js` instead of naming "Europe/Dublin" here.',
    },
  },
  createOnce(context) {
    return {
      before() {
        return !mayNameZone(context.filename);
      },
      Literal(node) {
        if (node.value === CLUB_TIME_ZONE) {
          context.report({ node, messageId: "dublinTimeZoneLiteral" });
        }
      },
      TemplateLiteral(node) {
        if (node.expressions.length === 0 && node.quasis[0]?.value.cooked === CLUB_TIME_ZONE) {
          context.report({ node, messageId: "dublinTimeZoneLiteral" });
        }
      },
    };
  },
});
