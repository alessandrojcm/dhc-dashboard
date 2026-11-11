defmodule Dhc.Destinations do
  @moduledoc """
  Domain-neutral rules for a workshop destination (ALE-438/ALE-440).

  A destination is the optional detail a short venue label alone cannot give an
  attendee: a recognizable name and address for the same place, plus an
  optional manually supplied Google Maps link used for directions. The label
  stays required and independent in every source context; a destination never
  replaces it.

  This module owns the rules every workshop-owning context shares:

    * which manually supplied URLs are supported HTTPS Maps destinations,
    * how the destination fields of a source schema are normalized and
      validated (`validate_changeset/1`), and
    * how a destination composes the recognizable Calendar location string,
      falling back to the source's own label when no destination is stored.

  It is deliberately free of workshop policy: storage, commands and scheduling
  stay with each source context (ADR 0029). No provider response shape lives
  here: lookups go through the separate `Dhc.Places` boundary, which writes
  nothing.

  ## Selected Google places (ALE-442)

  A destination staff deliberately selected from Google Maps venue search
  keeps only its provider identity, under the owner's ALE-439 decision
  (`docs/google-places-terms-validation.md`): `destination_provider`
  (`"google"`), `destination_place_id` and an application-generated
  `destination_selected_at`. Google's name, address and credits are a
  transient editing preview (`Dhc.Places.resolve/2`) and are never stored:
  `destination_name` and `destination_address` are always staff-typed text,
  whether or not a place is selected, and are what attendees and Calendar
  see. `validate_changeset/2` owns the provenance rules:

    * a new Place ID is a new selection: provider and timestamp are set, the
      staff text is kept as typed, and no manual link is kept, because a
      selected place's directions link is derived from the place;
    * clearing the Place ID clears the provider identity;
    * a manual directions link replaces the place: a supplied link means the
      staff chose a manual destination;
    * the place survives a name/address edit only when the same request
      resubmits its Place ID (the form shows the selected place beside the
      text and sends it back), so a caller that changes the text without
      naming the place cannot leave a stale ID pointing at another venue —
      the provider identity is cleared instead;
    * an unrelated edit (the destination omitted or resubmitted unchanged)
      preserves it, including its original selection timestamp.

  ## URL scope

  Only `https` links on Google's Maps surfaces are accepted: executable and
  non-secure schemes, embedded credentials, explicit ports, and hosts or paths
  outside Maps are refused. The check is a safety allowlist, not an attempt to
  prove the link resolves to a particular place; a name/address remains useful
  without a link, and a link without a provider listing is a valid destination.
  """

  @name_max 255
  @address_max 500
  @url_max 2048

  # `google.com` hosts serve Maps under a `/maps` path prefix; the dedicated
  # `maps.google.com` host is Maps-only, so any path is a Maps destination.
  @google_maps_path_hosts ~w(www.google.com google.com)
  @google_hosts ~w(maps.google.com)
  # Short-link hosts exist only for Maps, so any path is a Maps destination.
  @short_link_hosts ~w(maps.app.goo.gl)

  # Hosts whose links are Maps only when the path says so.
  @short_link_maps_path_hosts ~w(goo.gl g.co)

  @type url_error ::
          :invalid_url | :unsupported_scheme | :credentials | :unsupported_target

  @place_id_format ~r/\A[A-Za-z0-9_-]{1,255}\z/

  @text_fields [:destination_name, :destination_address, :directions_url]
  @fields @text_fields ++ [:destination_place_id]

  @doc """
  The destination fields a source context casts from a request, under the
  same names in every workshop-owning schema: `destination_name`,
  `destination_address`, `directions_url`, and (ALE-442) the selected
  `destination_place_id`. The provider and selection timestamp are never
  cast: `validate_changeset/2` sets them.
  """
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  The staff-entered destination fields (`destination_name`,
  `destination_address`, `directions_url`), without the selected-place
  identity of `fields/0`.
  """
  @spec text_fields() :: [atom()]
  def text_fields, do: @text_fields

  @doc "Whether `id` has the shape of a Google Place ID (safe in a URL path)."
  @spec valid_place_id?(term()) :: boolean()
  def valid_place_id?(id) when is_binary(id), do: Regex.match?(@place_id_format, id)
  def valid_place_id?(_id), do: false

  @doc """
  Normalizes and validates the destination fields of a source schema's
  changeset (ALE-440/ALE-441).

  The caller casts the fields itself, so each source context decides when a
  destination may change. An emptied or whitespace-only value becomes `nil`
  (absent); a supplied directions link must pass `validate_maps_url/1`, worded
  by `url_error_message/1`. Clearing a field (`nil`) is always valid.

  `opts[:now]` is the clock reading stamped on a new Google selection
  (defaults to the current time); see the moduledoc for the provenance rules.
  """
  @spec validate_changeset(Ecto.Changeset.t(), keyword()) :: Ecto.Changeset.t()
  def validate_changeset(%Ecto.Changeset{} = changeset, opts \\ []) do
    [:destination_place_id | @text_fields]
    |> Enum.reduce(changeset, fn field, acc ->
      case Ecto.Changeset.get_change(acc, field) do
        change when is_binary(change) ->
          Ecto.Changeset.put_change(acc, field, normalize_optional(change))

        _ ->
          acc
      end
    end)
    |> Ecto.Changeset.validate_length(:destination_name, max: @name_max)
    |> Ecto.Changeset.validate_length(:destination_address, max: @address_max)
    |> apply_provenance(opts)
    |> validate_directions_url()
  end

  # ── Provenance (ALE-442) ─────────────────────────────────────────────

  defp apply_provenance(changeset, opts) do
    case Ecto.Changeset.fetch_change(changeset, :destination_place_id) do
      {:ok, nil} ->
        clear_provenance(changeset)

      {:ok, place_id} ->
        select_place(changeset, place_id, opts)

      :error ->
        stored = changeset.data |> Map.get(:destination_place_id)

        cond do
          stored == nil ->
            changeset

          # A supplied manual link is a manual destination.
          is_binary(Ecto.Changeset.get_change(changeset, :directions_url)) ->
            clear_provenance(changeset)

          # New text without the place beside it: never keep a place the
          # caller did not name, which may now be a different venue.
          text_changed?(changeset) and resubmitted_place_id(changeset) != stored ->
            clear_provenance(changeset)

          true ->
            changeset
        end
    end
  end

  defp text_changed?(changeset),
    do:
      Map.has_key?(changeset.changes, :destination_name) or
        Map.has_key?(changeset.changes, :destination_address)

  defp resubmitted_place_id(%Ecto.Changeset{params: params}) when is_map(params),
    do: params |> Map.get("destination_place_id") |> text_value()

  defp resubmitted_place_id(_changeset), do: nil

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
      # A selected place's directions link is derived from it, so no
      # manually supplied (possibly stale) link survives a selection.
      |> Ecto.Changeset.put_change(:directions_url, nil)

    if valid_place_id?(place_id),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :destination_place_id, "is not a valid place")
  end

  # Only a *supplied* link is judged; clearing it (nil) is a valid edit.
  defp validate_directions_url(changeset) do
    with url when is_binary(url) <- Ecto.Changeset.get_field(changeset, :directions_url),
         {:error, reason} <- validate_maps_url(url) do
      Ecto.Changeset.add_error(changeset, :directions_url, url_error_message(reason))
    else
      _ok -> changeset
    end
  end

  @doc """
  The maximum length of a destination name.
  """
  @spec name_max() :: pos_integer()
  def name_max, do: @name_max

  @doc """
  The maximum length of a destination address.
  """
  @spec address_max() :: pos_integer()
  def address_max, do: @address_max

  @doc """
  The maximum length of a manually supplied directions link.
  """
  @spec url_max() :: pos_integer()
  def url_max, do: @url_max

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
  Whether a manually supplied directions link is a supported HTTPS Maps
  destination.

  `nil` (no link) is always allowed: the link is optional. Every refusal is a
  named reason from the closed `t:url_error/0` set.
  """
  @spec validate_maps_url(String.t() | nil) :: :ok | {:error, url_error()}
  def validate_maps_url(nil), do: :ok

  def validate_maps_url(url) when is_binary(url) do
    with :ok <- check_length(url),
         {:ok, uri} <- parse(url),
         :ok <- check_scheme(uri),
         :ok <- check_credentials(uri) do
      check_target(uri)
    end
  end

  def validate_maps_url(_other), do: {:error, :invalid_url}

  @doc """
  The one user-facing sentence for each `validate_maps_url/1` refusal.

  Source contexts render this as the field message on their own directions-link
  field, so both contexts word the same refusal the same way.
  """
  @spec url_error_message(url_error()) :: String.t()
  def url_error_message(:invalid_url), do: "Directions link must be a valid URL"
  def url_error_message(:unsupported_scheme), do: "Directions link must be an https link"

  def url_error_message(:credentials),
    do: "Directions link must not include a username or password"

  def url_error_message(:unsupported_target),
    do: "Directions link must be a Google Maps link"

  @doc """
  Composes the Calendar location string from a destination's name and address,
  falling back to the source's own venue label when neither is stored.

  The result is recognizable free-form text for Google's native event location
  field — never a link, and never a fabricated place for an unreviewed label.
  A destination with only a link keeps the label, because a URL is not a
  location people can read.
  """
  @spec calendar_location(String.t() | nil, String.t() | nil, String.t() | nil) ::
          String.t()
  def calendar_location(name, address, label) do
    composed =
      [name, address]
      |> Enum.map(&normalize_optional/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    if composed == "", do: normalize_optional(label) || "", else: composed
  end

  # ── URL checks ───────────────────────────────────────────────────────

  defp check_length(url) do
    if String.length(url) <= @url_max,
      do: :ok,
      else: {:error, :invalid_url}
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{} = uri} -> {:ok, uri}
      {:error, _part} -> {:error, :invalid_url}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) do
    if scheme != nil and String.downcase(scheme) == "https",
      do: :ok,
      else: {:error, :unsupported_scheme}
  end

  defp check_credentials(%URI{userinfo: nil}), do: :ok
  defp check_credentials(%URI{}), do: {:error, :credentials}

  # `URI.new/1` fills in the scheme's default port (443 for https), so only a
  # non-default explicit port is refused; no Maps share link carries one.
  defp check_target(%URI{port: port}) when is_integer(port) and port != 443,
    do: {:error, :unsupported_target}

  defp check_target(%URI{host: host, path: path}) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    cond do
      host in @google_maps_path_hosts -> maps_path?(path)
      host in @google_hosts -> :ok
      host in @short_link_hosts -> :ok
      host in @short_link_maps_path_hosts -> maps_path?(path)
      true -> {:error, :unsupported_target}
    end
  end

  defp check_target(_uri), do: {:error, :invalid_url}

  defp maps_path?(path) do
    if path in ["/maps", "/maps/"] or String.starts_with?(path || "", "/maps/"),
      do: :ok,
      else: {:error, :unsupported_target}
  end
end
