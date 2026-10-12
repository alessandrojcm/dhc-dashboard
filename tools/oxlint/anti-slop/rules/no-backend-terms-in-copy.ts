import { defineRule } from "@oxlint/plugins";
import type { ESTree } from "@oxlint/plugins";

import { findBackendTerm, isMachineToken } from "../shared/backend-terms.ts";

const TEST_FILE = /\.(?:test|spec)\.[cm]?[jt]sx?$|\/e2e\//;

/** A literal that names something rather than saying something to a reader. */
function isNonCopyPosition(node: ESTree.Node): boolean {
  const parent = node.parent;
  if (parent === undefined || parent === null) return false;
  switch (parent.type) {
    case "Property":
    case "PropertyDefinition":
    case "MethodDefinition":
    case "AccessorProperty":
    case "TSPropertySignature":
    case "TSEnumMember":
      return "key" in parent && parent.key === node;
    case "MemberExpression":
      return parent.property === node;
    case "ImportDeclaration":
    case "ExportNamedDeclaration":
    case "ExportAllDeclaration":
    case "ImportExpression":
    case "TSExternalModuleReference":
    case "TSLiteralType":
    case "TSModuleDeclaration":
    case "ImportAttribute":
    case "ImportSpecifier":
    case "ExportSpecifier":
      return true;
    default:
      return false;
  }
}

/**
 * Ban Beginners' Workshop domain terms (Intake, Batch, Carried Fee, …) in
 * string literals and template text: copy uses the vocabulary in AGENTS.md.
 */
export const noBackendTermsInCopyRule = defineRule({
  meta: {
    type: "problem",
    docs: {
      description:
        "Disallow Beginners' Workshop domain terms in staff- and person-facing string literals; use the copy vocabulary instead.",
    },
    messages: {
      backendTerm:
        'Copy shows the backend term "{{term}}"; say "{{copy}}" instead (AGENTS.md, Beginners\' Workshop copy vocabulary).',
    },
  },
  createOnce(context) {
    const check = (node: ESTree.Node, text: string) => {
      if (TEST_FILE.test(context.filename)) return;
      if (isMachineToken(text)) return;
      const found = findBackendTerm(text);
      if (found === undefined) return;
      context.report({
        node,
        messageId: "backendTerm",
        data: { term: found.term, copy: found.copy },
      });
    };

    return {
      Literal(node) {
        if (typeof node.value !== "string") return;
        if (isNonCopyPosition(node)) return;
        check(node, node.value);
      },
      TemplateLiteral(node) {
        if (node.parent?.type === "TSLiteralType") return;
        const text = node.quasis.map((quasi) => quasi.value.cooked ?? quasi.value.raw).join("");
        check(node, text);
      },
    };
  },
});
