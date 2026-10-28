defmodule Dhc.BeginnersWorkshops.OfferRoundDeliveryTest do
  use Dhc.DataCase, async: false
  use Oban.Testing, repo: Dhc.Repo

  import Kernel, except: [round: 1]

  import Dhc.BeginnersWorkshopFixtures

  alias Dhc.BeginnersWorkshops
  alias Dhc.BeginnersWorkshops.{Clock, IntakeEmailLog}
  alias Dhc.Email.{Mailer, OfferRoundWorker, Worker}

  defp round(count) do
    workshop =
      scheduled_fixture(staff_fixture(), %{"contact_from" => "2026-10-20", "capacity" => count})

    people = waiting_people_fixture(count)
    {workshop, people}
  end

  defp send_round(workshop) do
    BeginnersWorkshops.execute(:system, {:send_due_batch, workshop.id},
      clock: Clock.fixed(batch_1_at())
    )
  end

  defp capture_request(conn, parent, status \\ 200) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    envelopes = Jason.decode!(body)
    send(parent, {:request, body, Plug.Conn.get_req_header(conn, "idempotency-key")})

    response =
      if status == 200,
        do: %{data: Enum.map(envelopes, fn _ -> %{id: Ecto.UUID.generate()} end)},
        else: %{name: "validation_error", message: "private provider content"}

    Plug.Conn.resp(conn, status, Jason.encode!(response))
  end

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:dhc, Mailer)

    Application.put_env(:dhc, Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: "re_local_test",
      base_url: "http://localhost:#{bypass.port}"
    )

    on_exit(fn -> Application.put_env(:dhc, Mailer, original) end)
    %{bypass: bypass}
  end

  for size <- [100, 101] do
    test "#{size} people have stable ordered chunks of at most 100", ctx do
      size = unquote(size)
      {workshop, people} = round(size)
      parent = self()
      Bypass.expect(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
      assert {:ok, %{batch: round}} = send_round(workshop)
      jobs = Enum.sort_by(all_enqueued(worker: OfferRoundWorker), & &1.args["chunk"])
      assert Enum.map(jobs, & &1.args["count"]) == if(size == 100, do: [100], else: [100, 1])
      for job <- jobs, do: assert(:ok = OfferRoundWorker.perform(job))

      requests =
        for _ <- jobs do
          assert_receive {:request, body, [key]}
          {Jason.decode!(body), key}
        end

      assert Enum.flat_map(requests, fn {messages, _key} ->
               Enum.flat_map(messages, & &1["to"])
             end) == Enum.map(people, & &1.email)

      assert Enum.map(requests, &elem(&1, 1)) ==
               Enum.map(jobs, &"beginners-offer-round:#{round.id}:#{&1.args["chunk"]}")

      assert {:ok, %{outcome: :not_due}} = send_round(workshop)
      assert length(all_enqueued(worker: OfferRoundWorker)) == length(jobs)
    end
  end

  test "mixed pay and confirmation messages keep personal links and per-email Reply-To bindings",
       ctx do
    original_domain = Application.get_env(:dhc, :intake_reply_domain)
    Application.put_env(:dhc, :intake_reply_domain, "reply.example.test")
    on_exit(fn -> Application.put_env(:dhc, :intake_reply_domain, original_domain) end)
    {workshop, [payer, confirmer]} = round(2)

    Repo.insert!(%Dhc.BeginnersWorkshops.CarriedFee{
      waitlist_id: confirmer.id,
      status: "held",
      origin: "import",
      imported_paid_text: "Yes",
      status_changed_at: batch_1_at()
    })

    parent = self()
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    for person <- [payer, confirmer], do: refute(Jason.encode!(job.args) =~ person.email)
    assert :ok = OfferRoundWorker.perform(job)
    assert_receive {:request, body, [_key]}
    [pay, confirm] = Jason.decode!(body)
    assert pay["to"] == [payer.email]
    assert confirm["to"] == [confirmer.email]
    assert pay["template"]["variables"]["BUTTON_LABEL"] == "Pay for your place"
    assert confirm["template"]["variables"]["BUTTON_LABEL"] == "Confirm my place"
    assert pay["reply_to"] != confirm["reply_to"]

    for {message, person, type} <- [
          {pay, payer, "contact_pay"},
          {confirm, confirmer, "contact_confirm"}
        ] do
      assert {:ok, binding} = Dhc.BeginnersWorkshops.IntakeReplies.resolve(message["reply_to"])
      assert binding.waitlist_entry.id == person.id
      assert binding.email_type == type

      assert message["template"]["variables"]["BUTTON_URL"] ==
               Dhc.BeginnersWorkshops.IntakeLink.url(
                 Dhc.BeginnersWorkshops.IntakeLink.token(binding.intake.id, 1)
               )
    end

    assert Enum.sort(Repo.all(from(l in IntakeEmailLog, select: l.email_type))) == [
             "contact_confirm",
             "contact_pay"
           ]
  end

  test "a retry after 5xx preserves the wire payload despite mutable domain and config edits",
       ctx do
    {workshop, [person]} = round(1)
    parent = self()
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent, 503))
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    assert {:error, {:offer_round_delivery, 503}} = OfferRoundWorker.perform(%{job | attempt: 1})
    assert_receive {:request, first, key}

    Repo.update_all(from(p in Dhc.UserProfiles.UserProfile, where: p.waitlist_id == ^person.id),
      set: [first_name: "Changed"]
    )

    Repo.update_all(Dhc.BeginnersWorkshops.IntakeEmails.Template, set: [subject: "Changed"])

    Repo.update_all(
      from(w in Dhc.BeginnersWorkshops.BeginnersWorkshop, where: w.id == ^workshop.id),
      set: [venue: "Changed"]
    )

    original_from = Application.get_env(:dhc, :email_from)
    original_reply = Application.get_env(:dhc, :email_reply_to)
    Application.put_env(:dhc, :email_from, "changed@example.test")
    Application.put_env(:dhc, :email_reply_to, "changed@example.test")

    on_exit(fn ->
      Application.put_env(:dhc, :email_from, original_from)
      Application.put_env(:dhc, :email_reply_to, original_reply)
    end)

    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
    assert :ok = OfferRoundWorker.perform(%{job | attempt: 2})
    assert_receive {:request, ^first, ^key}
  end

  test "rollback leaves no chunk, occasion, Intake, offer round or reply binding", _ctx do
    original_domain = Application.get_env(:dhc, :intake_reply_domain)
    Application.put_env(:dhc, :intake_reply_domain, "reply.example.test")
    on_exit(fn -> Application.put_env(:dhc, :intake_reply_domain, original_domain) end)
    {workshop, _people} = round(2)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert {:ok, _} = send_round(workshop)
               assert Repo.aggregate(Dhc.BeginnersWorkshops.IntakeReplyAddress, :count) == 2
               Repo.rollback(:rollback)
             end)

    for schema <- [
          Dhc.BeginnersWorkshops.Batch,
          Dhc.BeginnersWorkshops.Intake,
          IntakeEmailLog,
          Dhc.BeginnersWorkshops.IntakeReplyAddress
        ],
        do: assert(Repo.aggregate(schema, :count) == 0)

    assert all_enqueued(worker: OfferRoundWorker) == []
  end

  test "a strict rejection explicitly reports all affected messages without regrouping", ctx do
    Sentry.Test.setup_sentry()
    {workshop, _people} = round(2)
    parent = self()
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent, 422))
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    assert {:cancel, {:provider_rejected, 422}} = OfferRoundWorker.perform(job)
    assert [%{extra: %{count: 2, round_id: round_id}} = event] = Sentry.Test.pop_sentry_reports()
    assert round_id == job.args["round_id"]
    refute inspect(event) =~ "private"
    assert [^job] = all_enqueued(worker: OfferRoundWorker)
    assert all_enqueued(worker: Worker) == []
  end

  test "malformed recipients refuse the command before any occasion or delivery commits" do
    {workshop, [_valid, invalid]} = round(2)

    Repo.update_all(from(e in Dhc.Waitlist.WaitlistEntry, where: e.id == ^invalid.id),
      set: [email: "not-an-address"]
    )

    assert {:error, :invalid_offer_round_envelope} = send_round(workshop)
    assert all_enqueued(worker: OfferRoundWorker) == []
    assert Repo.aggregate(IntakeEmailLog, :count) == 0
    assert Repo.aggregate(Dhc.BeginnersWorkshops.Intake, :count) == 0
  end

  test "empty rounds send nothing and fast-track still uses the individual worker", ctx do
    staff = staff_fixture()
    workshop = scheduled_fixture(staff, %{"contact_from" => "2026-10-20"})
    assert {:ok, %{outcome: :nobody_waiting}} = send_round(workshop)
    assert all_enqueued(worker: OfferRoundWorker) == []
    person = waiting_person_fixture(~U[2025-01-01 12:00:00Z])

    assert {:ok, _} =
             BeginnersWorkshops.execute(
               {:staff, staff},
               {:fast_track, workshop.id, {:waitlist_entry, person.id}},
               clock: Clock.fixed(batch_1_at())
             )

    assert [job] = all_enqueued(worker: Worker)
    parent = self()

    Bypass.expect_once(ctx.bypass, "POST", "/emails", fn conn ->
      send(parent, :individual)
      Plug.Conn.resp(conn, 200, Jason.encode!(%{id: "individual"}))
    end)

    assert :ok = Worker.perform(job)
    assert_receive :individual
    assert all_enqueued(worker: OfferRoundWorker) == []
  end

  test "429 retries preserve the request and apply the account cooldown", ctx do
    {workshop, _} = round(1)
    parent = self()

    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "5") |> capture_request(parent, 429)
    end)

    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    assert {:error, {:offer_round_delivery, 429}} = OfferRoundWorker.perform(job)
    assert_receive {:request, first, key}
    assert %{num_rows: 1} = Repo.query!("SELECT * FROM resend_request_gate")
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
    assert :ok = OfferRoundWorker.perform(job)
    assert_receive {:request, ^first, ^key}
  end

  test "timeout after receiving a request retries identical content without regrouping", ctx do
    {workshop, _} = round(1)
    parent = self()

    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:pending, self(), body, Plug.Conn.get_req_header(conn, "idempotency-key")})

      receive do: (:release ->
                     Plug.Conn.resp(conn, 200, Jason.encode!(%{data: [%{id: "accepted"}]})))
    end)

    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    # Bound only the test transport, not the request payload. Finch's default
    # timeout races Cowboy's idle timeout on a busy full-suite run.
    secret = DhcWeb.Endpoint.config(:secret_key_base)
    salt = "dhc.email.offer_round envelopes v1"
    {:ok, frozen} = Plug.Crypto.decrypt(secret, salt, job.args["sealed_envelopes"])

    frozen = %{
      frozen
      | emails:
          Enum.map(
            frozen.emails,
            &Swoosh.Email.put_private(&1, :client_options, receive_timeout: 200)
          )
    }

    job = %{
      job
      | args: Map.put(job.args, "sealed_envelopes", Plug.Crypto.encrypt(secret, salt, frozen))
    }

    task = Task.async(fn -> OfferRoundWorker.perform(job) end)
    assert_receive {:pending, server, body, key}
    assert {:error, {:offer_round_delivery, :transport_failure}} = Task.await(task, 30_000)
    send(server, :release)
    Bypass.down(ctx.bypass)
    Bypass.up(ctx.bypass)
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
    assert :ok = OfferRoundWorker.perform(job)
    assert_receive {:request, ^body, ^key}
    assert [_one] = all_enqueued(worker: OfferRoundWorker)
  end

  test "expired seals and delivery windows cancel visibly without HTTP" do
    Sentry.Test.setup_sentry(dedup_events: false)
    {workshop, _} = round(1)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    secret = DhcWeb.Endpoint.config(:secret_key_base)
    salt = "dhc.email.offer_round envelopes v1"

    {:ok, frozen} =
      Plug.Crypto.decrypt(secret, salt, job.args["sealed_envelopes"], max_age: 86_400)

    for sealed <- [
          Plug.Crypto.encrypt(secret, salt, frozen,
            signed_at: System.system_time(:second) - 86_401
          ),
          Plug.Crypto.encrypt(secret, salt, %{frozen | deadline: System.system_time(:second) - 1})
        ] do
      assert {:cancel, :expired_delivery} =
               OfferRoundWorker.perform(%{
                 job
                 | args: Map.put(job.args, "sealed_envelopes", sealed)
               })

      assert [%{extra: %{delivery_failure: :expired_delivery}}] = Sentry.Test.pop_sentry_reports()
    end

    assert {:cancel, :invalid_batch} =
             OfferRoundWorker.perform(%{job | args: Map.put(job.args, "chunk", 1)})
  end

  test "exhausted delivery is explicit and contains no provider content or ciphertext", ctx do
    Sentry.Test.setup_sentry()
    {workshop, _} = round(2)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    parent = self()
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent, 503))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:cancel, {:exhausted_delivery, 503}} =
                 OfferRoundWorker.perform(%{job | attempt: 5})
      end)

    assert [event] = Sentry.Test.pop_sentry_reports()
    assert event.extra.delivery_failure == :exhausted_delivery
    assert event.extra.count == 2

    for value <- ["private", job.args["sealed_envelopes"], "waitlist.example.com"],
        do: refute(inspect(event) <> log =~ value)
  end

  test "actual Swoosh batch requests pass the shared gate outside command transactions", ctx do
    {workshop, _} = round(1)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    original = Application.get_env(:dhc, :environment)
    Application.put_env(:dhc, :environment, :prod)
    on_exit(fn -> Application.put_env(:dhc, :environment, original) end)
    parent = self()

    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", fn conn ->
      assert %{num_rows: 1} = Repo.query!("SELECT * FROM resend_request_gate")
      capture_request(conn, parent)
    end)

    assert :ok = OfferRoundWorker.perform(job)
    assert_receive {:request, _body, [_key]}

    assert_raise RuntimeError, ~r/outside transactions/, fn ->
      Repo.transaction(fn -> OfferRoundWorker.perform(job) end)
    end
  end

  test "production's named sender is supported and frozen", ctx do
    original = Application.get_env(:dhc, :email_from)
    Application.put_env(:dhc, :email_from, "Dublin HEMA Club <info@dublinhemaclub.com>")
    on_exit(fn -> Application.put_env(:dhc, :email_from, original) end)
    {workshop, _} = round(1)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    parent = self()
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
    assert :ok = OfferRoundWorker.perform(job)
    assert_receive {:request, body, [_key]}
    assert [%{"from" => "Dublin HEMA Club <info@dublinhemaclub.com>"}] = Jason.decode!(body)
  end

  test "incomplete provider receipts are not claimed as successful delivery", ctx do
    {workshop, _} = round(1)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)

    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{data: [%{}]}))
    end)

    assert {:error, {:offer_round_delivery, :invalid_provider_response}} =
             OfferRoundWorker.perform(job)
  end

  test "non-provider delivery retains the dev inbox's readable personal summary" do
    Application.put_env(:dhc, Mailer, adapter: Swoosh.Adapters.Test)
    {workshop, [person]} = round(1)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    assert :ok = OfferRoundWorker.perform(job)
    assert_received {:emails, [email]}
    assert Jason.decode!(email.text_body)["email"] == person.email
    assert Jason.decode!(email.text_body)["data_variables"]["BUTTON_URL"] =~ "/beginners/intake/"
  end

  test "Oban retries only the failed chunk, retaining a completed chunk's identity", ctx do
    Sentry.Test.setup_sentry()
    {workshop, people} = round(101)
    parent = self()

    Bypass.expect(ctx.bypass, "POST", "/emails/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      messages = Jason.decode!(body)
      send(parent, {:chunk, body, Plug.Conn.get_req_header(conn, "idempotency-key")})

      if match?([_one], messages) do
        Plug.Conn.resp(conn, 503, Jason.encode!(%{message: "private failure"}))
      else
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{data: Enum.map(messages, fn _ -> %{id: Ecto.UUID.generate()} end)})
        )
      end
    end)

    assert {:ok, _} = send_round(workshop)
    assert %{success: 1, failure: 1} = Oban.drain_queue(queue: :emails)
    assert Sentry.Test.pop_sentry_reports() == []

    requests =
      for _ <- 1..2 do
        assert_receive {:chunk, body, key}
        {body, key}
      end

    {failed_body, failed_key} =
      Enum.find(requests, fn {body, _} -> match?([_one], Jason.decode!(body)) end)

    assert hd(Jason.decode!(failed_body))["to"] == [List.last(people).email]

    assert [failed] =
             Repo.all(
               from(j in Oban.Job,
                 where: j.worker == "Dhc.Email.OfferRoundWorker" and j.state == "retryable"
               )
             )

    assert :ok = Oban.retry_job(failed.id)
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent))
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :emails)
    assert_receive {:request, ^failed_body, ^failed_key}

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "Dhc.Email.OfferRoundWorker" and j.state == "completed"
             ),
             :count
           ) == 2
  end

  test "actual Oban exhaustion reports once and stores only safe error reasons", ctx do
    Sentry.Test.setup_sentry()
    {workshop, _} = round(1)
    assert {:ok, _} = send_round(workshop)
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [attempt: 4])
    parent = self()
    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", &capture_request(&1, parent, 503))
    assert %{cancelled: 1} = Oban.drain_queue(queue: :emails)
    assert [event] = Sentry.Test.pop_sentry_reports()
    assert event.extra.delivery_failure == :exhausted_delivery
    assert event.extra.oban_attempt == 5
    stored = Repo.get!(Oban.Job, job.id)

    for secret <- ["private", job.args["sealed_envelopes"]],
        do: refute(inspect(stored.errors) <> inspect(event) =~ secret)
  end

  test "one offer round sends one batch of personalized messages, not individual requests", ctx do
    workshop =
      scheduled_fixture(staff_fixture(), %{"contact_from" => "2026-10-20", "capacity" => 3})

    people = waiting_people_fixture(3)
    parent = self()

    Bypass.expect_once(ctx.bypass, "POST", "/emails/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:batch, Jason.decode!(body), Plug.Conn.get_req_header(conn, "idempotency-key")}
      )

      Plug.Conn.resp(conn, 200, Jason.encode!(%{data: for(n <- 1..3, do: %{id: "email-#{n}"})}))
    end)

    assert {:ok, %{outcome: :sent, batch: round}} =
             BeginnersWorkshops.execute(:system, {:send_due_batch, workshop.id},
               clock: Clock.fixed(batch_1_at())
             )

    assert all_enqueued(worker: Worker) == []
    assert [job] = all_enqueued(worker: OfferRoundWorker)
    assert :ok = OfferRoundWorker.perform(job)
    assert_receive {:batch, envelopes, [key]}
    assert key == "beginners-offer-round:#{round.id}:0"
    assert Enum.map(envelopes, & &1["to"]) == Enum.map(people, &[&1.email])

    assert [_first, _second, _third] =
             Enum.uniq(Enum.map(envelopes, & &1["template"]["variables"]["BUTTON_URL"]))

    for envelope <- envelopes do
      refute Map.has_key?(envelope, "cc")
      refute Map.has_key?(envelope, "bcc")
      assert envelope["template"]["id"] == "beginners-workshop-action"
    end

    assert Repo.aggregate(IntakeEmailLog, :count) == 3
  end
end
