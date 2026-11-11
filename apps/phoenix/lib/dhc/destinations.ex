defmodule Dhc.Destinations do
  @moduledoc """
  Domain-neutral rules for a workshop destination (ALE-438/ALE-440/ALE-442).

  A destination is the optional detail a short venue label alone cannot give an
  attendee. Staff enter it through one autocomplete input, so a saved
  destination is exactly one of:

    * **manual text** (`destination_text`): what staff typed without choosing
      a suggestion — a recognizable name and/or address, shown to attendees
      beside the label and used as the Calendar location; or
    * **a selected Google place**: only its provider identity —
      `destination_provider` (`"google"`), `destination_place_id` and an
      application-generated `destination_selected_at` — under the owner's
      ALE-439 decision (`docs/google-places-terms-validation.md`). Google's
      name, address and credits are a transient editing preview
      (`Dhc.Places.resolve/2`) and are never stored. Attendees see the label
      and a directions link to the place; Calendar sees the label.

  Never both: the two are mutually exclusive in `validate_changeset/2` and in
  each table's `*_destination_text_or_place` check. The label stays required
  and independent in every source context; a destination never replaces it.

  This module owns the rules every workshop-owning context shares: how the
  destination fields of a source schema are normalized and validated, and how
  a destination composes the Calendar location string. It is deliberately
  free of workshop policy: storage, commands and scheduling stay with each
  source context (ADR 0029). No provider response shape lives here: lookups
  go through the separate `Dhc.Places` boundary, which writes nothing.

  ## Provenance rules (`validate_changeset/2`)

    * a new Place ID is a new selection: provider and timestamp are set and
      the stored manual text is cleared;
    * clearing the Place ID clears the provider identity;
    * manual text supplied without naming the stored place replaces it;
    * manual text beside a Place ID (new or resubmitted) is refused — a saved
      destination is a place or text, never both;
    * an unrelated edit (the destination omitted or resubmitted unchanged)
      preserves a place, including its original selection timestamp.
  """

  @text_max 500

  @place_id_format ~r/\A[A-Za-z0-9_-]{1,255}\z/

  @fields [:destination_text, :destination_place_id]

  @doc """
  The destination fields a source context casts from a request, under the
  same names in every workshop-owning schema: the manual `destination_text`
  and (ALE-442) the selected `destination_place_id`. The provider and
  selection timestamp are never cast: `validate_changeset/2` sets them.
  """
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc "Whether `id` has the shape of a Google Place ID (safe in a URL path)."
  @spec valid_place_id?(term()) :: boolean()
  def valid_place_id?(id) when is_binary(id), do: Regex.match?(@place_id_format, id)
  def valid_place_id?(_id), do: false

  @doc """
  Normalizes and validates the destination fields of a source schema's
  changeset.

  The caller casts the fields itself, so each source context decides when a
  destination may change. An emptied or whitespace-only value becomes `nil`
  (absent); clearing a field is always valid.

  `opts[:now]` is the clock reading stamped on a new Google selection
  (defaults to the current time); see the moduledoc for the provenance rules.
  """
  @spec validate_changeset(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_changeset(%Ecto.Changeset{} = changeset, opts \\ []) do
    @fields
    |> Enum.reduce(changeset, fn field, acc ->
      case Ecto.Changeset.get_change(acc, field) do
        change when is_binary(change) ->
          Ecto.Changeset.put_change(acc, field, normalize_optional(change))

        _ ->
          acc
      end
    end)
    |> Ecto.Changeset.validate_length(:destination_text, max: @text_max)
    |> apply_provenance(opts)
    |> validate_text_or_place()
  end

  # ── Provenance (ALE-442) ─────────────────────────────────────────────

  defp apply_provenance(changeset, opts) do
    case Ecto.Changeset.fetch_change(changeset, :destination_place_id) do
      {:ok, nil} ->
        clear_provenance(changeset)

      {:ok, place_id} ->
        select_place(changeset, place_id, opts)

      :error ->
        stored = Map.get(changeset.data, :destination_place_id)

        # Manual text without the place beside it is a manual destination:
        # never keep a place the caller did not name.
        if stored != nil and text_supplied?(changeset) and
             resubmitted_place_id(changeset) != stored,
           do: clear_provenance(changeset),
           else: changeset
    end
  end

  # Judged on the request itself, so text resubmitted unchanged beside a
  # Place ID is still text beside a place.
  defp text_supplied?(changeset), do: is_binary(param(changeset, "destination_text"))

  defp resubmitted_place_id(changeset), do: param(changeset, "destination_place_id")

  defp param(%Ecto.Changeset{params: params}, key) when is_map(params),
    do: params |> Map.get(key) |> text_value()

  defp param(_changeset, _key), do: nil

  defp text_value(value) when is_binary(value), do: normalize_optional(value)
  defp text_value(_value), do: nil

  defp clear_provenance(changeset) do
    changeset
    |> Ecto.Changeset.put_change(:destination_provider, nil)
    |> Ecto.Changeset.put_change(:destination_place_id, nil)
    |> Ecto.Changeset.put_change(:destination_selected_at, nil)
  end

  defp select_place(changeset, place_id, opts) do
    now =
      opts
      |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
      |> DateTime.truncate(:second)

    changeset =
      changeset
      |> Ecto.Changeset.put_change(:destination_provider, "google")
      |> Ecto.Changeset.put_change(:destination_selected_at, now)
      # A selection replaces the stored manual text; text supplied beside it
      # is left for `validate_text_or_place/1` to refuse.
      |> then(fn cs ->
        if text_supplied?(cs), do: cs, else: Ecto.Changeset.put_change(cs, :destination_text, nil)
      end)

    if valid_place_id?(place_id),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :destination_place_id, "is not a valid place")
  end

  defp validate_text_or_place(changeset) do
    if is_binary(Ecto.Changeset.get_field(changeset, :destination_text)) and
         is_binary(Ecto.Changeset.get_field(changeset, :destination_place_id)),
       do:
         Ecto.Changeset.add_error(
           changeset,
           :destination_text,
           "Choose a suggested place or type the destination, not both"
         ),
       else: changeset
  end

  @doc "The maximum length of manual destination text."
  @spec text_max() :: pos_integer()
  def text_max, do: @text_max

  @doc """
  Trims optional destination text, treating an empty string as absent.

  Both source contexts normalize destination input through this so an emptied
  form field clears the stored detail instead of persisting whitespace.
  """
  @spec normalize_optional(String.t() | nil) :: String.t() | nil
  def normalize_optional(nil), do: nil

  def normalize_optional(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  The Calendar location string: the manual destination text, falling back to
  the source's own venue label when none is stored.

  A selected Google place keeps the label — no Google text is stored to
  compose from (an accepted trade-off of the Place-ID-only decision) — and
  nothing here fabricates a place for an unreviewed label.
  """
  @spec calendar_location(String.t() | nil, String.t() | nil) :: String.t()
  def calendar_location(text, label),
    do: normalize_optional(text) || normalize_optional(label) || ""
end
