# Inventory copy

Overrides `MASTER.md` for inventory, equipment, and loan screens.

## Voice

Club language, not warehouse language. Quartermasters are members who look after kit — not "operators".

## Vocabulary

| Say | Don't say |
|-----|-----------|
| Quartermaster | Operator, inventory operator |
| Item (one tracked piece) | Physical item, physical unit, inventory unit |
| Gear (the collection) | Equipment register, physical units |
| Code (`item-000001`) | Slug |
| Notes | Operator notes, current facts |
| Container / location | Placement (in helper text) |

The page eyebrow on quartermaster screens is **Quartermaster**. On member screens it is **Club gear**.

## Keep in code, not on screen

`{:operator, id}`, `inventory.manage`, `OperatorLoans`, and OpenAPI `operator` fields stay as they are. Admin and president who can manage inventory are still addressed as quartermasters in the UI — they are doing that job.
