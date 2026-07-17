defmodule Dhc.Stripe.SourceTypeKlarna do
  @moduledoc """
  Provides struct and type for a SourceTypeKlarna
  """

  @type t :: %__MODULE__{
          background_image_url: String.t() | nil,
          client_token: String.t() | nil,
          first_name: String.t() | nil,
          last_name: String.t() | nil,
          locale: String.t() | nil,
          logo_url: String.t() | nil,
          page_title: String.t() | nil,
          pay_later_asset_urls_descriptive: String.t() | nil,
          pay_later_asset_urls_standard: String.t() | nil,
          pay_later_name: String.t() | nil,
          pay_later_redirect_url: String.t() | nil,
          pay_now_asset_urls_descriptive: String.t() | nil,
          pay_now_asset_urls_standard: String.t() | nil,
          pay_now_name: String.t() | nil,
          pay_now_redirect_url: String.t() | nil,
          pay_over_time_asset_urls_descriptive: String.t() | nil,
          pay_over_time_asset_urls_standard: String.t() | nil,
          pay_over_time_name: String.t() | nil,
          pay_over_time_redirect_url: String.t() | nil,
          payment_method_categories: String.t() | nil,
          purchase_country: String.t() | nil,
          purchase_type: String.t() | nil,
          redirect_url: String.t() | nil,
          shipping_delay: integer | nil,
          shipping_first_name: String.t() | nil,
          shipping_last_name: String.t() | nil
        }

  defstruct [
    :background_image_url,
    :client_token,
    :first_name,
    :last_name,
    :locale,
    :logo_url,
    :page_title,
    :pay_later_asset_urls_descriptive,
    :pay_later_asset_urls_standard,
    :pay_later_name,
    :pay_later_redirect_url,
    :pay_now_asset_urls_descriptive,
    :pay_now_asset_urls_standard,
    :pay_now_name,
    :pay_now_redirect_url,
    :pay_over_time_asset_urls_descriptive,
    :pay_over_time_asset_urls_standard,
    :pay_over_time_name,
    :pay_over_time_redirect_url,
    :payment_method_categories,
    :purchase_country,
    :purchase_type,
    :redirect_url,
    :shipping_delay,
    :shipping_first_name,
    :shipping_last_name
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      background_image_url: :string,
      client_token: :string,
      first_name: :string,
      last_name: :string,
      locale: :string,
      logo_url: :string,
      page_title: :string,
      pay_later_asset_urls_descriptive: :string,
      pay_later_asset_urls_standard: :string,
      pay_later_name: :string,
      pay_later_redirect_url: :string,
      pay_now_asset_urls_descriptive: :string,
      pay_now_asset_urls_standard: :string,
      pay_now_name: :string,
      pay_now_redirect_url: :string,
      pay_over_time_asset_urls_descriptive: :string,
      pay_over_time_asset_urls_standard: :string,
      pay_over_time_name: :string,
      pay_over_time_redirect_url: :string,
      payment_method_categories: :string,
      purchase_country: :string,
      purchase_type: :string,
      redirect_url: :string,
      shipping_delay: :integer,
      shipping_first_name: :string,
      shipping_last_name: :string
    ]
  end
end
