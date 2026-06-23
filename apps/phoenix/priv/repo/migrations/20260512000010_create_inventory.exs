defmodule Dhc.Repo.Migrations.CreateInventory do
  use Ecto.Migration

  def up do
    # ── containers ──────────────────────────────────────────
    # `timestamps(inserted_at: :created_at)` — the production `containers`
    # table uses `created_at`/`updated_at`, not `inserted_at`/`updated_at`.
    # Mirrors the `user_profiles`/`member_profiles`/`club_activities` baseline
    # pattern (see AGENTS.md `created_at` vs `inserted_at` divergence note).
    create table(:containers, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :description, :text
      add :parent_container_id, references(:containers, type: :uuid, on_delete: :delete_all)

      add :created_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing),
        null: false

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:containers, [:parent_container_id])
    create index(:containers, [:created_by])

    # ── equipment_categories ────────────────────────────────
    # `timestamps(inserted_at: :created_at)` — same rationale as `containers`.
    create table(:equipment_categories, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :description, :text
      add :available_attributes, :map, null: false, default: fragment("'{}'::jsonb")
      add :attribute_schema, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create unique_index(:equipment_categories, [:name])

    # ── inventory_items ─────────────────────────────────────
    # `timestamps(inserted_at: :created_at)` — same rationale as `containers`
    # and `equipment_categories`. The production `inventory_items` table uses
    # `created_at`/`updated_at`; the Inventory Item list read (ALE-99) orders
    # by `created_at desc, id desc`.
    create table(:inventory_items, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :container_id, references(:containers, type: :uuid, on_delete: :nothing), null: false

      add :category_id, references(:equipment_categories, type: :uuid, on_delete: :nothing),
        null: false

      add :attributes, :map, null: false, default: fragment("'{}'::jsonb")
      add :quantity, :integer, null: false, default: 1
      add :photo_url, :text
      add :out_for_maintenance, :boolean, default: false
      add :notes, :text
      add :created_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)
      add :updated_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing)

      timestamps(type: :timestamptz, inserted_at: :created_at)
    end

    create index(:inventory_items, [:container_id])
    create index(:inventory_items, [:category_id])
    create index(:inventory_items, [:out_for_maintenance])

    execute "ALTER TABLE inventory_items ADD CONSTRAINT quantity_positive CHECK (quantity > 0)"

    # ── inventory_history ───────────────────────────────────
    create table(:inventory_history, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :item_id, references(:inventory_items, type: :uuid, on_delete: :delete_all), null: false
      add :action, :inventory_action, null: false
      add :old_container_id, references(:containers, type: :uuid, on_delete: :nothing)
      add :new_container_id, references(:containers, type: :uuid, on_delete: :nothing)

      add :changed_by, references(:users, prefix: "auth", type: :uuid, on_delete: :nothing),
        null: false

      add :notes, :text
      add :created_at, :timestamptz, default: fragment("NOW()")
    end

    create index(:inventory_history, [:item_id])
    create index(:inventory_history, [:action])
    create index(:inventory_history, [:changed_by])

    # Seed default equipment categories. The table has NOT NULL
    # `created_at`/`updated_at` from `timestamps(inserted_at: :created_at)`,
    # so populate them.
    execute """
    INSERT INTO equipment_categories (name, description, available_attributes, created_at, updated_at) VALUES
    ('Masks', 'Protective masks for HEMA practice',
      '[{"name": "brand", "type": "text", "required": true, "label": "Brand"}, {"name": "size", "type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false, "label": "Size"}, {"name": "colour", "type": "text", "required": false, "label": "Colour"}]'::jsonb, NOW(), NOW()),
    ('Gorgets', 'Throat protection for HEMA practice',
      '[{"name": "brand", "type": "text", "required": true, "label": "Brand"}]'::jsonb, NOW(), NOW()),
    ('Gloves', 'Hand protection for HEMA practice',
      '[{"name": "brand", "type": "text", "required": true, "label": "Brand"}, {"name": "colour", "type": "text", "required": false, "label": "Colour"}, {"name": "model", "type": "text", "required": false, "label": "Model"}]'::jsonb, NOW(), NOW()),
    ('Plastrons', 'Chest protection for HEMA practice',
      '[{"name": "size", "type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false, "label": "Size"}, {"name": "type", "type": "select", "options": ["female", "male"], "required": false, "label": "Type"}]'::jsonb, NOW(), NOW()),
    ('Jackets', 'Protective jackets for HEMA practice',
      '[{"name": "brand", "type": "text", "required": true, "label": "Brand"}, {"name": "colour", "type": "text", "required": false, "label": "Colour"}, {"name": "size", "type": "select", "options": ["XS", "S", "M", "L", "XL"], "required": false, "label": "Size"}]'::jsonb, NOW(), NOW()),
    ('Arming Swords', 'Single-handed swords for HEMA practice',
      '[{"name": "brand", "type": "text", "required": true, "label": "Brand"}, {"name": "model", "type": "text", "required": false, "label": "Model"}]'::jsonb, NOW(), NOW()),
    ('Longswords', 'Two-handed swords for HEMA practice',
      '[{"name": "brand", "type": "text", "required": true, "label": "Brand"}, {"name": "model", "type": "text", "required": false, "label": "Model"}]'::jsonb, NOW(), NOW())
    """
  end

  def down do
    drop table(:inventory_history)
    drop table(:inventory_items)
    drop table(:equipment_categories)
    drop table(:containers)
  end
end
