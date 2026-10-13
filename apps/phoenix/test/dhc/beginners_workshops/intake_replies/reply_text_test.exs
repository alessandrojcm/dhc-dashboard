defmodule Dhc.BeginnersWorkshops.IntakeReplies.ReplyTextTest do
  # Every fixture is synthetic: a rendered Intake Email quoted the way each
  # client quotes it. Never paste a real reply in here.
  use ExUnit.Case, async: true

  alias Dhc.BeginnersWorkshops.IntakeEmails.Renderer
  alias Dhc.BeginnersWorkshops.IntakeReplies.ReplyText

  @intake_link "https://dashboard.dublinhemaclub.com/beginners/intake/k3J9xQ2mT7vLp0aZ"
  @club "Dublin HEMA Club"
  @sender "noreply@dublinhemaclub.com"
  @reply_address "7f3kq9zt2m4x8p1c6v5b0n3h2j4k6l8m9q1w3e5r@reply.dublinhemaclub.com"

  @values %{
    "firstName" => "Aoife",
    "date" => "Saturday 14 November 2026",
    "startTime" => "10:00",
    "venue" => "St. Michan's Hall",
    "fee" => "€50.00",
    "windowEnd" => "Sunday 8 November 2026, 23:59",
    "paymentCutoff" => "Wednesday 11 November 2026, 23:59"
  }

  defp t(text), do: %{"type" => "text", "text" => text}
  defp ph(name), do: %{"type" => "placeholder", "attrs" => %{"name" => name}}
  defp p(content), do: %{"type" => "paragraph", "content" => content}

  # The Contact email as the Email Kind wrapper sends it: the rendered
  # template body, then the button carrying the Intake link.
  defp intake_email_html do
    body = %{
      "type" => "doc",
      "content" => [
        p([t("Hi "), ph("firstName"), t(",")]),
        p([
          t("A place is waiting for you at the Beginners' Workshop on "),
          ph("date"),
          t(" at "),
          ph("startTime"),
          t(", "),
          ph("venue"),
          t(".")
        ]),
        p([t("The fee is "), ph("fee"), t(". Please pay by "), ph("windowEnd"), t(".")])
      ]
    }

    {:ok, html} = Renderer.render_body("contact_pay", body, @values)

    """
    <html><head><style>p { margin: 0 0 12px; }</style></head><body>
    #{html}
    <p><a href="#{@intake_link}" class="button">Pay for your place</a></p>
    <p>If the button does not work, open #{@intake_link}</p>
    </body></html>
    """
  end

  defp intake_email_text do
    """
    Hi Aoife,

    A place is waiting for you at the Beginners' Workshop on Saturday 14 November 2026 at 10:00, St. Michan's Hall.

    The fee is €50.00. Please pay by Sunday 8 November 2026, 23:59.

    Pay for your place: #{@intake_link}
    """
  end

  defp quoted(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ">"
      line -> "> " <> line
    end)
  end

  defp refute_leaks(text) do
    refute text =~ "beginners/intake"
    refute text =~ "k3J9xQ2mT7vLp0aZ"
    refute text =~ "@"
    refute text =~ "A place is waiting"
  end

  describe "replies from each client to a rendered Intake Email" do
    test "Gmail web: the attribution wraps over two lines" do
      text = """
      Hi, sorry, I can't make that date. Could I do a later one?

      Thanks,
      Jane

      On Mon, 12 Oct 2026 at 10:00, #{@club} <
      #{@sender}> wrote:

      #{quoted(intake_email_text())}
      """

      html = """
      <div dir="ltr">Hi, sorry, I can&#39;t make that date. Could I do a later one?<div><br></div><div>Thanks,</div><div>Jane</div></div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, 12 Oct 2026 at 10:00, #{@club} &lt;<a href="mailto:#{@sender}">#{@sender}</a>&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex">#{intake_email_html()}</blockquote></div>
      """

      expected = "Hi, sorry, I can't make that date. Could I do a later one?\n\nThanks,\nJane"

      assert {:ok, ^expected} = ReplyText.extract(%{text: text, html: html})
      assert {:ok, ^expected} = ReplyText.extract(%{text: nil, html: html})
      refute_leaks(expected)
    end

    test "Gmail on Android" do
      text = """
      Please take me off the waitlist, I've joined another club.

      On Mon, 12 Oct 2026, 10:00 #{@club}, <#{@sender}> wrote:

      #{quoted(intake_email_text())}
      """

      assert {:ok, result} = ReplyText.extract(%{text: text, html: nil})
      assert result == "Please take me off the waitlist, I've joined another club."
      refute_leaks(result)
    end

    test "Gmail on iOS, with a mobile footer" do
      text = """
      The pay button isn't working for me

      Sent from Gmail for iPhone

      On Mon, Oct 12, 2026 at 10:00 AM #{@club} <#{@sender}> wrote:

      #{quoted(intake_email_text())}
      """

      assert {:ok, "The pay button isn't working for me"} =
               ReplyText.extract(%{text: text, html: nil})
    end

    test "Apple Mail on iPhone: the attribution is itself quoted" do
      text = """
      I'd like my money back please.

      Sent from my iPhone

      > On 12 Oct 2026, at 10:00, #{@club} <#{@sender}> wrote:
      >\s
      #{quoted(intake_email_text())}
      """

      html = """
      <html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"></head><body dir="auto"><div dir="ltr">I’d like my money back please.</div><div dir="ltr"><br><div dir="ltr">Sent from my iPhone</div><div dir="ltr"><br><blockquote type="cite">On 12 Oct 2026, at 10:00, #{@club} &lt;#{@sender}&gt; wrote:<br><br></blockquote></div><blockquote type="cite"><div dir="ltr">#{intake_email_html()}</div></blockquote></div></body></html>
      """

      assert {:ok, "I'd like my money back please."} = ReplyText.extract(%{text: text, html: nil})
      assert {:ok, "I’d like my money back please."} = ReplyText.extract(%{text: "", html: html})
    end

    test "Outlook desktop: the From/Sent/To/Subject header block and its rule" do
      text = """
      Hello,

      Something came up at work, I can't attend on the 14th.

      Regards,
      Jane Doe

      ________________________________
      From: #{@club} <#{@sender}>
      Sent: Monday, 12 October 2026 10:00
      To: Jane Doe <jane.doe@example.com>
      Subject: Your Beginners' Workshop place

      Hi Aoife,

      A place is waiting for you at the Beginners' Workshop on Saturday 14 November 2026.

      Pay for your place<#{@intake_link}>
      """

      assert {:ok, result} = ReplyText.extract(%{text: text, html: nil})

      assert result ==
               "Hello,\n\nSomething came up at work, I can't attend on the 14th.\n\nRegards,\nJane Doe"

      refute_leaks(result)
    end

    test "Outlook web: HTML only, the header block inside divRplyFwdMsg" do
      html = """
      <html><head><style type="text/css" style="display:none;"> P {margin-top:0;margin-bottom:0;} </style></head>
      <body dir="ltr"><div class="elementToProof" style="font-family: Aptos, sans-serif;">
      Can you resend the link? The old one says it has expired.</div>
      <div id="appendonsend"></div><hr style="display:inline-block;width:98%" tabindex="-1">
      <div id="divRplyFwdMsg" dir="ltr"><font face="Calibri, sans-serif" style="font-size:11pt"><b>From:</b> #{@club} &lt;#{@sender}&gt;<br>
      <b>Sent:</b> Monday, October 12, 2026 10:00 AM<br>
      <b>To:</b> Jane Doe &lt;jane.doe@example.com&gt;<br>
      <b>Subject:</b> Your Beginners' Workshop place</font>
      <div>&nbsp;</div></div>
      #{intake_email_html()}
      </body></html>
      """

      assert {:ok, result} = ReplyText.extract(%{text: nil, html: html})
      assert result == "Can you resend the link? The old one says it has expired."
      refute_leaks(result)
    end
  end

  describe "redaction" do
    test "a reply that quotes the Intake link inline redacts it, and every address" do
      text = """
      This link doesn't open: #{@intake_link}
      You can also reach me at jane.doe+hema@example.com or reply to #{@reply_address}.
      (See www.example.com/help, or mailto:jane@example.ie.)
      """

      assert {:ok, result} = ReplyText.extract(%{text: text, html: nil})

      assert result ==
               "This link doesn't open: [link]\n" <>
                 "You can also reach me at [email] or reply to [email].\n" <>
                 "(See [link], or mailto:[email].)"

      refute_leaks(result)
    end

    test "a link typed without its scheme is still a link" do
      text =
        "try dashboard.dublinhemaclub.com/beginners/intake/k3J9xQ2mT7vLp0aZ, it fails. St. Michan's is fine."

      assert {:ok, "try [link], it fails. St. Michan's is fine."} =
               ReplyText.extract(%{text: text, html: nil})
    end

    test "an address spelt with HTML entities is decoded before it is redacted" do
      html = "<p>jane&commat;example&period;com or jane&#64;example&#46;ie</p>"
      assert {:ok, "[email] or [email]"} = ReplyText.extract(%{text: nil, html: html})
    end

    test "quoting that no rule recognises still loses its link and addresses" do
      text = """
      yes please

      #{@club} wrote on Monday
      Pay for your place: #{@intake_link}
      Questions? #{@sender}
      """

      assert {:ok, result} = ReplyText.extract(%{text: text, html: nil})
      refute result =~ "beginners/intake"
      refute result =~ "@"
      assert result =~ "Pay for your place: [link]"
    end
  end

  describe "what is cut" do
    test "a reply that is only a signature is empty" do
      text = """

      --\s
      Jane Doe
      Dublin, Ireland
      Sent from my iPhone

      On Mon, 12 Oct 2026 at 10:00, #{@club} <#{@sender}> wrote:
      #{quoted(intake_email_text())}
      """

      assert :empty = ReplyText.extract(%{text: text, html: nil})
    end

    test "the signature delimiter cuts what follows" do
      assert {:ok, "See you there"} =
               ReplyText.extract(%{text: "See you there\n-- \nJane\n087 123 4567", html: nil})
    end

    test "Original Message, forwarded-message markers and Outlook mobile footers" do
      for marker <- [
            "-----Original Message-----",
            "---------- Forwarded message ---------",
            "Begin forwarded message:",
            "Get Outlook for Android",
            "Sent from Outlook for iOS"
          ] do
        text = "Withdraw me please\r\n\r\n#{marker}\r\nFrom: #{@club}\r\n#{intake_email_text()}"
        assert {:ok, "Withdraw me please"} = ReplyText.extract(%{text: text, html: nil})
      end
    end

    test "a From: line on its own is the person's words, not a header block" do
      text = "From: next month I'm free on Saturdays\nThanks"

      assert {:ok, "From: next month I'm free on Saturdays\nThanks"} =
               ReplyText.extract(%{text: text, html: nil})
    end

    test "the result is capped at 2,000 characters" do
      long = String.duplicate("I really cannot make it. ", 200)
      assert {:ok, result} = ReplyText.extract(%{text: long, html: nil})
      assert String.length(result) <= 2_000
      assert String.starts_with?(result, "I really cannot make it.")
    end
  end

  describe "choosing a part" do
    test "uses the text part when there is one" do
      assert {:ok, "plain"} = ReplyText.extract(%{text: "plain", html: "<p>html</p>"})
    end

    test "falls back to HTML when the text part is missing or blank, decoding entities" do
      html =
        "<p>Fish &amp; chips &lt;3 &#8364;50 &#x2014; caf&eacute;</p><script>x()</script><!-- c --><p>ok</p>"

      assert {:ok, "Fish & chips <3 €50 — café\nok"} =
               ReplyText.extract(%{text: "  \n", html: html})
    end

    test "nothing at all is empty" do
      assert :empty = ReplyText.extract(%{text: nil, html: nil})
      assert :empty = ReplyText.extract(%{text: "", html: "<div><br></div>"})
    end
  end
end
