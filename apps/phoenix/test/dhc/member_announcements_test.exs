defmodule Dhc.MemberAnnouncementsTest do
  use Dhc.DataCase, async: true
  use Oban.Testing, repo: Dhc.Repo

  import Swoosh.TestAssertions

  alias Dhc.MemberAnnouncements
  alias Dhc.MemberAnnouncements.Announcement
  alias Dhc.MemberAnnouncements.Delivery
  alias Dhc.MemberAnnouncements.Document
  alias Dhc.MemberAnnouncements.Workers.DeliveryWorker
  alias Dhc.MemberFixtures

  defp doc(content), do: %{"type" => "doc", "content" => content}
  defp text(value, marks \\ []), do: %{"type" => "text", "text" => value, "marks" => marks}
  defp paragraph(children), do: %{"type" => "paragraph", "content" => children}

  defp draft(attrs \\ %{}) do
    Map.merge(
      %{"subject" => "AGM", "body" => doc([paragraph([text("See you there")])])},
      attrs
    )
  end

  describe "Document.render/1" do
    test "renders the closed vocabulary with inline styles and escapes text" do
      body =
        doc([
          %{"type" => "heading", "attrs" => %{"level" => 2}, "content" => [text("Agenda")]},
          paragraph([
            text("<b>", [%{"type" => "bold"}]),
            %{"type" => "hardBreak"},
            text("link", [%{"type" => "link", "attrs" => %{"href" => "https://dhc.ie/?a=1&b=2"}}])
          ]),
          %{
            "type" => "bulletList",
            "content" => [%{"type" => "listItem", "content" => [paragraph([text("one")])]}]
          },
          %{
            "type" => "orderedList",
            "attrs" => %{"start" => 3},
            "content" => [%{"type" => "listItem", "content" => [paragraph([text("three")])]}]
          },
          %{"type" => "blockquote", "content" => [paragraph([text("quoted")])]},
          %{"type" => "horizontalRule"}
        ])

      assert {:ok, %{html: html, text: text}} = Document.render(body)

      assert html =~ ~r/<h2 style="[^"]+">Agenda<\/h2>/
      assert html =~ ~r/<strong style="[^"]+">&lt;b&gt;<\/strong>/
      assert html =~ ~s(href="https://dhc.ie/?a=1&amp;b=2")
      assert html =~ ~s(target="_blank")
      assert html =~ ~s(<ol start="3")
      assert html =~ "<blockquote"
      assert html =~ "<hr"
      refute html =~ "<b>"

      assert text =~ "• one"
      assert text =~ "3. three"
      assert text =~ "> quoted"
      assert text =~ "link (https://dhc.ie/?a=1&b=2)"
    end

    test "rejects anything outside the vocabulary" do
      assert {:error, "contains unsupported content (codeBlock)"} =
               Document.render(doc([%{"type" => "codeBlock"}]))

      assert {:error, "contains unsupported formatting (code)"} =
               Document.render(doc([paragraph([text("x", [%{"type" => "code"}])])]))

      assert {:error, "only supports headings 2 and 3"} =
               Document.render(doc([%{"type" => "heading", "attrs" => %{"level" => 1}}]))

      assert {:error, "is not a rich-text document"} = Document.render("<p>hi</p>")
    end

    test "rejects javascript: and relative links" do
      for href <- ["javascript:alert(1)", "/relative", "data:text/html,x"] do
        body = doc([paragraph([text("x", [%{"type" => "link", "attrs" => %{"href" => href}}])])])
        assert {:error, "links must start with" <> _} = Document.render(body)
      end
    end

    test "rejects a document without visible text" do
      assert {:error, "must contain some text"} = Document.render(doc([paragraph([])]))
      assert {:error, "must contain some text"} = Document.render(doc([]))
    end
  end

  describe "audience" do
    test "active members by default, inactive members only when included" do
      MemberFixtures.member_fixture(email: "Active@Example.com", is_active: true)
      MemberFixtures.member_fixture(email: "lapsed@example.com", is_active: false)

      assert MemberAnnouncements.recipient_emails(false) == ["active@example.com"]

      assert MemberAnnouncements.recipient_emails(true) == [
               "active@example.com",
               "lapsed@example.com"
             ]

      assert MemberAnnouncements.recipient_count(false) == 1
      assert MemberAnnouncements.recipient_count(true) == 2
    end
  end

  describe "preview/1" do
    test "renders the full shell with the escaped subject and counts recipients" do
      MemberFixtures.member_fixture(is_active: true)

      assert {:ok, preview} = MemberAnnouncements.preview(draft(%{"subject" => "Tom & Jerry"}))

      assert preview.html =~ "Tom &amp; Jerry"
      assert preview.html =~ "See you there"
      refute preview.html =~ "{{{"
      assert preview.recipient_count == 1
    end

    test "returns field errors" do
      assert {:error, changeset} =
               MemberAnnouncements.preview(%{"subject" => " ", "body" => doc([])})

      assert %{subject: [_], body: [_]} = errors_on(changeset)
    end
  end

  describe "send_announcement/2 and delivery" do
    setup do
      sender = MemberFixtures.member_fixture(is_active: true)
      %{sender_id: sender.auth_user_id}
    end

    test "freezes recipients and enqueues one delivery job", %{sender_id: sender_id} do
      MemberFixtures.member_fixture(is_active: false)

      assert {:ok, %Announcement{} = announcement} =
               MemberAnnouncements.send_announcement(sender_id, draft())

      assert announcement.status == :queued
      assert announcement.recipient_count == 1
      assert_enqueued(worker: DeliveryWorker, args: %{"announcement_id" => announcement.id})
    end

    test "is refused when the audience is empty" do
      principal = Dhc.AuthFixtures.principal_fixture()

      Repo.update_all(Dhc.UserProfiles.UserProfile, set: [is_active: false])

      assert {:error, :no_recipients} =
               MemberAnnouncements.send_announcement(principal.id, draft())
    end

    test "BCCs recipients in groups of 49 inside one batch request", %{sender_id: sender_id} do
      for _ <- 1..99, do: MemberFixtures.member_fixture(is_active: true)

      {:ok, announcement} = MemberAnnouncements.send_announcement(sender_id, draft())
      assert announcement.recipient_count == 100

      assert [[first | _] = batch] = Delivery.batches(announcement)
      assert Enum.map(batch, &length(&1.bcc)) == [49, 49, 2]
      assert first.provider_options.idempotency_key == "member-announcement:#{announcement.id}:0"

      assert :ok = perform_job(DeliveryWorker, %{"announcement_id" => announcement.id})
      assert_received {:emails, [_, _, _]}

      sent = Repo.get!(Announcement, announcement.id)
      assert sent.status == :sent
      assert sent.sent_at

      # A redelivered job does not send again.
      assert :ok = perform_job(DeliveryWorker, %{"announcement_id" => announcement.id})
      refute_received {:emails, _}
      refute_email_sent()
    end
  end
end
