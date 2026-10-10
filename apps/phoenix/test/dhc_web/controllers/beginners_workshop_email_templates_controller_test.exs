defmodule DhcWeb.BeginnersWorkshopEmailTemplatesControllerTest do
  @moduledoc """
  ALE-383 contract: the Intake Email template slice behind
  `beginners.workshops.manage`, with its named save refusals.
  """

  use DhcWeb.ConnCase, async: false

  alias Dhc.BeginnersWorkshops.IntakeEmails
  alias Dhc.BeginnersWorkshops.IntakeEmails.EmailType
  alias Dhc.MemberFixtures
  alias DhcWeb.OpenApiVerifier

  @managers ~w(beginners_coordinator admin president committee_coordinator)
  @others ~w(coach treasurer workshop_coordinator member)
  @path "/api/beginners-workshops/email-templates"

  defp doc(blocks), do: %{"type" => "doc", "content" => blocks}
  defp p(content), do: %{"type" => "paragraph", "content" => content}
  defp t(text), do: %{"type" => "text", "text" => text}
  defp ph(name), do: %{"type" => "placeholder", "attrs" => %{"name" => name}}

  setup do
    roles = @managers ++ @others
    role_subs = Map.new(roles, &{&1, Ecto.UUID.generate()})

    for {_role, id} <- role_subs do
      MemberFixtures.member_fixture(principal_id: id, is_active: true)
    end

    original = OpenApiVerifier.install(roles: roles, role_subs: role_subs)
    on_exit(fn -> OpenApiVerifier.restore(original) end)
    :ok
  end

  defp as(role), do: build_conn() |> put_req_header("authorization", "Bearer #{role}-token")

  describe "GET /beginners-workshops/email-templates" do
    test "lists every type in display order with its kind, button and placeholders" do
      for role <- @managers do
        assert %{"data" => templates} = role |> as() |> get(@path) |> json_response(200)
        assert Enum.map(templates, & &1["emailType"]) == EmailType.ids()

        assert %{
                 "kind" => "action",
                 "buttonLabel" => "Pay for your place",
                 "placeholders" => [
                   "firstName",
                   "date",
                   "startTime",
                   "venue",
                   "fee",
                   "windowEnd",
                   "paymentCutoff"
                 ],
                 "subject" => subject,
                 "body" => %{"type" => "doc"},
                 "updatedAt" => updated_at
               } = hd(templates)

        assert is_binary(subject)
        assert {:ok, _, _} = DateTime.from_iso8601(updated_at)

        assert %{"kind" => "notice", "buttonLabel" => nil, "placeholders" => ["firstName"]} =
                 Enum.find(templates, &(&1["emailType"] == "withdrawn_forfeited"))
      end
    end

    test "requires a session and beginners.workshops.manage" do
      assert build_conn() |> get(@path) |> json_response(401)

      for role <- @others do
        assert %{"errors" => %{"detail" => "Insufficient role"}} =
                 role |> as() |> get(@path) |> json_response(403)
      end
    end
  end

  describe "PUT /beginners-workshops/email-templates/:emailType" do
    test "saves the subject and body and returns the saved template" do
      body = doc([p([t("Thanks, "), ph("firstName")])])

      assert %{
               "data" => %{
                 "emailType" => "follow_up",
                 "subject" => "Thanks for {{date}}",
                 "body" => ^body
               }
             } =
               "beginners_coordinator"
               |> as()
               |> put("#{@path}/follow_up", %{"subject" => "Thanks for {{date}}", "body" => body})
               |> json_response(200)

      assert %{subject: "Thanks for {{date}}", body: ^body} =
               IntakeEmails.get_template!("follow_up")
    end

    test "refuses a placeholder the type can't fill, by name, in either field" do
      response =
        "admin"
        |> as()
        |> put("#{@path}/withdrawn_forfeited", %{
          "subject" => "See you on {{date}}",
          "body" => doc([p([ph("venue")])])
        })
        |> json_response(422)

      assert %{
               "errors" => %{
                 "code" => "placeholder_not_allowed",
                 "detail" => "The template uses a placeholder this email can't fill",
                 "fields" => %{
                   "subject" => ["uses {{date}}, which this email can't fill"],
                   "body" => ["uses {{venue}}, which this email can't fill"]
                 }
               }
             } = response
    end

    test "refuses a template over the limit at worst case" do
      response =
        "president"
        |> as()
        |> put("#{@path}/contact_pay", %{
          "subject" => "A place for you",
          "body" => doc([p(List.duplicate(ph("venue"), 25))])
        })
        |> json_response(422)

      assert %{
               "errors" => %{
                 "code" => "template_too_long",
                 "fields" => %{"body" => ["is 2007 characters" <> _]}
               }
             } = response
    end

    test "refuses any other invalid template" do
      assert %{"errors" => %{"code" => "invalid_template", "fields" => %{"subject" => [_]}}} =
               "admin"
               |> as()
               |> put("#{@path}/declined", %{"subject" => " ", "body" => doc([p([t("Hi")])])})
               |> json_response(422)
    end

    test "an unknown email type is not found" do
      assert %{"errors" => %{"detail" => "Intake Email type not found"} = errors} =
               "admin"
               |> as()
               |> put("#{@path}/coach_reminder", %{"subject" => "Hi", "body" => doc([])})
               |> json_response(404)

      refute Map.has_key?(errors, "code")
    end

    test "requires beginners.workshops.manage" do
      before = IntakeEmails.get_template!("declined")

      for role <- @others do
        assert role
               |> as()
               |> put("#{@path}/declined", %{"subject" => "Hi", "body" => doc([p([t("Hi")])])})
               |> json_response(403)
      end

      assert IntakeEmails.get_template!("declined") == before
    end
  end
end
