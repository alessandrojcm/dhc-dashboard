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
  stay with each source context (ADR 0029), and no provider response shape or
  provider identity lives here — a Google-selected destination (later work)
  will reuse these seams without either context importing the other.

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

  @fields [:destination_name, :destination_address, :directions_url]

  @doc """
  The destination fields every workshop-owning schema stores under the same
  names: `destination_name`, `destination_address` and `directions_url`.
  """
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  Normalizes and validates the destination fields of a source schema's
  changeset (ALE-440/ALE-441).

  The caller casts the fields itself, so each source context decides when a
  destination may change. An emptied or whitespace-only value becomes `nil`
  (absent); a supplied directions link must pass `validate_maps_url/1`, worded
  by `url_error_message/1`. Clearing a field (`nil`) is always valid.
  """
  @spec validate_changeset(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def validate_changeset(%Ecto.Changeset{} = changeset) do
    @fields
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
    |> validate_directions_url()
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
