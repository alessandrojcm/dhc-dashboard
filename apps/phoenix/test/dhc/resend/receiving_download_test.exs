defmodule Dhc.Resend.ReceivingDownloadTest do
  @moduledoc """
  Security-audit run-1, lead 8: `Receiving.download/1` fetches only https
  URLs on Resend's own hosts (or the configured allow-list extension), never
  follows redirects, and refuses everything else without a request.
  """

  use ExUnit.Case, async: false

  alias Dhc.Resend.Receiving
  alias Dhc.Resend.Receiving.DownloadUrl

  describe "download/1" do
    test "refuses non-https, userinfo, private and unknown hosts without any request" do
      Req.Test.stub(Dhc.Resend, fn _conn -> raise "download must not fetch a refused URL" end)

      for url <- [
            "http://resend-raw.test/raw/x",
            "https://u:p@resend-raw.test/raw/x",
            "https://evil.example/raw/x",
            "https://localhost/raw/x",
            "https://127.0.0.1/raw/x",
            "not a url"
          ] do
        assert {:error, :invalid_response} = Receiving.download(url)
      end
    end
  end

  describe "DownloadUrl.allowed_host?/1" do
    test "accepts Resend's documented download hosts" do
      assert DownloadUrl.allowed_host?("inbound-cdn.resend.com")
      assert DownloadUrl.allowed_host?("raw.resend.com")
      assert DownloadUrl.allowed_host?("inbound-cdn.RESEND.com.")
    end

    test "accepts the configured test hosts" do
      assert DownloadUrl.allowed_host?("resend-raw.test")
      assert DownloadUrl.allowed_host?("resend-cdn.test")
    end

    test "rejects lookalikes and non-hosts" do
      refute DownloadUrl.allowed_host?("evilresend.com")
      refute DownloadUrl.allowed_host?("resend.com.attacker.example")
      refute DownloadUrl.allowed_host?(".resend.com")
      refute DownloadUrl.allowed_host?("")
      refute DownloadUrl.allowed_host?(nil)
    end
  end
end
