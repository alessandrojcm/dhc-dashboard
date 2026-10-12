import { RuleTester } from "oxlint/plugins-dev";
import { describe, it } from "vitest";

import { noDublinTimeZoneLiteralRule } from "./no-dublin-time-zone-literal.ts";

RuleTester.describe = describe;
RuleTester.it = it;

const tester = new RuleTester({ languageOptions: { sourceType: "module" } });

const formatter = `const format = new Intl.DateTimeFormat("en-IE", { timeZone: "Europe/Dublin" });`;

tester.run("no-dublin-time-zone-literal", noDublinTimeZoneLiteralRule, {
  valid: [
    { name: "the Club Calendar module names the zone", code: formatter, filename: "/repo/apps/web/src/lib/club-calendar.ts" },
    { name: "a unit test may name the zone", code: formatter, filename: "/repo/apps/web/src/lib/beginners-workshops/console.test.ts" },
    {
      name: "a browser test may name the zone",
      code: formatter,
      filename: "/repo/apps/web/src/lib/components/ui/date-picker.browser.test.ts",
    },
    { name: "an end-to-end spec may name the zone", code: formatter, filename: "/repo/apps/web/e2e/training-announcements.spec.ts" },
    {
      name: "a throwaway prototype may name the zone",
      code: formatter,
      filename: "/repo/apps/web/src/routes/dashboard/prototype/calendar/fixtures.ts",
    },
    {
      name: "importing the zone is allowed",
      code: `import { CLUB_TIME_ZONE } from "#lib/club-calendar.js";
const format = new Intl.DateTimeFormat("en-IE", { timeZone: CLUB_TIME_ZONE });`,
      filename: "/repo/apps/web/src/lib/beginners-workshops/console.ts",
    },
    {
      name: "a comment or another zone is allowed",
      code: `/** Shown on the Europe/Dublin wall clock. */ const zone = "Europe/London";`,
      filename: "/repo/apps/web/src/lib/beginners-workshops/console.ts",
    },
  ],
  invalid: [
    {
      name: "a feature module names the zone",
      code: formatter,
      filename: "/repo/apps/web/src/lib/beginners-workshops/console.ts",
      errors: [{ messageId: "dublinTimeZoneLiteral" }],
    },
    {
      name: "a template literal names the zone",
      code: "const zone = `Europe/Dublin`;",
      filename: "/repo/apps/web/src/lib/inventory/member-loans.svelte.ts",
      errors: [{ messageId: "dublinTimeZoneLiteral" }],
    },
    {
      name: "a file merely called club-calendar.ts elsewhere",
      code: formatter,
      filename: "/repo/apps/web/src/lib/other/club-calendar.ts",
      errors: [{ messageId: "dublinTimeZoneLiteral" }],
    },
    {
      name: "a route whose name only starts with prototype",
      code: formatter,
      filename: "/repo/apps/web/src/routes/dashboard/prototypes-index/+page.ts",
      errors: [{ messageId: "dublinTimeZoneLiteral" }],
    },
  ],
});
