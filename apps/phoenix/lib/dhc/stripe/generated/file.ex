defmodule Dhc.Stripe.File do
  @moduledoc """
  Provides struct and type for a File
  """

  @type t :: %__MODULE__{
          created: integer,
          expires_at: integer | nil,
          filename: String.t() | nil,
          id: String.t(),
          links: Dhc.Stripe.FileResourceFileLinkList.t() | nil,
          object: String.t(),
          purpose: String.t(),
          size: integer,
          title: String.t() | nil,
          type: String.t() | nil,
          url: String.t() | nil
        }

  defstruct [
    :created,
    :expires_at,
    :filename,
    :id,
    :links,
    :object,
    :purpose,
    :size,
    :title,
    :type,
    :url
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      created: {:integer, "unix-time"},
      expires_at: {:integer, "unix-time"},
      filename: :string,
      id: :string,
      links: {Dhc.Stripe.FileResourceFileLinkList, :t},
      object: {:const, "file"},
      purpose:
        {:enum,
         [
           "account_requirement",
           "additional_verification",
           "business_icon",
           "business_logo",
           "customer_signature",
           "dispute_evidence",
           "document_provider_identity_document",
           "finance_report_run",
           "financial_account_statement",
           "identity_document",
           "identity_document_downloadable",
           "issuing_regulatory_reporting",
           "pci_document",
           "platform_terms_of_service",
           "selfie",
           "sigma_scheduled_query",
           "tax_document_user_upload",
           "terminal_android_apk",
           "terminal_reader_splashscreen",
           "terminal_wifi_certificate",
           "terminal_wifi_private_key"
         ]},
      size: :integer,
      title: :string,
      type: :string,
      url: :string
    ]
  end
end
