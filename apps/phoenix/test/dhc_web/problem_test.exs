defmodule DhcWeb.ProblemTest do
  use DhcWeb.ConnCase, async: true

  alias DhcWeb.Problem

  defmodule SampleHTTP do
    use DhcWeb.Problem,
      reasons: %{
        taken: {409, "Name is taken"},
        bad_dates: {:unprocessable_entity, "Dates are invalid"},
        sibling_taken: {409, "Sibling name is taken", :taken},
        gone: {404, "Thing not found"},
        upstream: {502, "Provider failed"},
        bad_query: {400, "Invalid query"}
      },
      fields: %{starts_on: "startDate", one_off_date: "oneOffDate"}
  end

  defmodule Sample do
    use Ecto.Schema

    embedded_schema do
      field :starts_on, :date
      field :max_capacity, :integer
      field :title, :string

      embeds_many :values, Value do
        field :text, :string
      end
    end
  end

  defp render(result, module \\ SampleHTTP) do
    conn = module.call(build_conn(), module.init(result))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  describe "body shape" do
    test "every body carries errors.detail" do
      assert {404, %{"errors" => errors}} = render({:error, :gone})
      assert errors == %{"detail" => "Thing not found"}
    end

    test "body/2 builds the same shape for renderers without a reason table" do
      assert Problem.body("Not Found") == %{errors: %{detail: "Not Found"}}

      assert Problem.body("Nope", code: :nope, fields: %{"a" => ["b"]}) ==
               %{errors: %{detail: "Nope", code: "nope", fields: %{"a" => ["b"]}}}
    end
  end

  describe "code" do
    test "is the snake_case reason on 409 and 422" do
      assert {409, %{"errors" => %{"code" => "taken", "detail" => "Name is taken"}}} =
               render({:error, :taken})

      assert {422, %{"errors" => %{"code" => "bad_dates"}}} = render({:error, :bad_dates})
    end

    test "can be overridden so two reasons share one public code" do
      assert {409, %{"errors" => %{"code" => "taken", "detail" => "Sibling name is taken"}}} =
               render({:error, :sibling_taken})
    end

    test "is absent for generic 400/401/403/404/5xx reasons" do
      for reason <- [:gone, :upstream, :bad_query, :forbidden, :unauthorized, :not_found] do
        assert {_status, %{"errors" => errors}} = render({:error, reason})
        refute Map.has_key?(errors, "code"), "#{reason} must not carry a code"
      end
    end

    test "is absent for a plain changeset" do
      changeset = Ecto.Changeset.add_error(Ecto.Changeset.change(%Sample{}), :title, "is bad")
      assert {422, %{"errors" => errors}} = render({:error, changeset})
      refute Map.has_key?(errors, "code")
    end
  end

  describe "shared reasons" do
    test "not_found, forbidden and unauthorized render without a fallback module" do
      assert {404, %{"errors" => %{"detail" => "Not found"}}} =
               render({:error, :not_found}, Problem)

      assert {403, %{"errors" => %{"detail" => "Insufficient role"}}} =
               render({:error, :forbidden}, Problem)

      assert {401, %{"errors" => %{"detail" => "Unauthorized"}}} =
               render({:error, :unauthorized}, Problem)
    end

    test "send_reason/2 halts for plugs" do
      conn = Problem.send_reason(build_conn(), :forbidden)
      assert conn.halted
      assert conn.status == 403
      assert %{"errors" => %{"detail" => "Insufficient role"}} = Jason.decode!(conn.resp_body)
    end

    test "a domain module may override a shared detail" do
      defmodule OverrideHTTP do
        use DhcWeb.Problem, reasons: %{not_found: {404, "Workshop not found"}}
      end

      assert {404, %{"errors" => %{"detail" => "Workshop not found"}}} =
               render({:error, :not_found}, OverrideHTTP)
    end

    test "an undeclared reason raises instead of leaking a 500 body" do
      assert_raise ArgumentError, ~r/undeclared error reason :mystery/, fn ->
        render({:error, :mystery})
      end
    end
  end

  describe "changesets" do
    test "map fields to public names, fill placeholders, and build detail from fields" do
      changeset =
        %Sample{}
        |> Ecto.Changeset.cast(%{max_capacity: 0}, [:starts_on, :max_capacity, :title])
        |> Ecto.Changeset.validate_required([:starts_on])
        |> Ecto.Changeset.validate_number(:max_capacity, greater_than: 1)
        |> Ecto.Changeset.validate_length(:title, min: 3)
        |> Ecto.Changeset.add_error(:title, "should be at least %{count} character(s)",
          count: 3,
          validation: :length
        )

      assert {422, %{"errors" => %{"detail" => detail, "fields" => fields}}} =
               render({:error, changeset})

      assert fields == %{
               "startDate" => ["can't be blank"],
               "maxCapacity" => ["must be greater than 1"],
               "title" => ["should be at least 3 character(s)"]
             }

      assert detail ==
               "maxCapacity: must be greater than 1; startDate: can't be blank; " <>
                 "title: should be at least 3 character(s)"
    end

    test "unmapped snake_case fields are camelCased, nested errors use dotted paths" do
      changeset =
        %Sample{}
        |> Ecto.Changeset.cast(%{values: [%{text: "ok"}, %{}]}, [])
        |> Ecto.Changeset.cast_embed(:values,
          with: fn value, attrs ->
            value
            |> Ecto.Changeset.cast(attrs, [:text])
            |> Ecto.Changeset.validate_required([:text])
          end
        )

      assert {422, %{"errors" => %{"fields" => fields}}} = render({:error, changeset})
      assert fields == %{"values.1.text" => ["can't be blank"]}
    end
  end

  describe "other result shapes" do
    test "a reason with field messages keeps the reason's status, detail and code" do
      assert {422,
              %{
                "errors" => %{
                  "detail" => "Dates are invalid",
                  "code" => "bad_dates",
                  "fields" => %{"startDate" => ["is in the past"], "values.abc" => ["required"]}
                }
              }} =
               render(
                 {:error, :bad_dates,
                  %{"starts_on" => ["is in the past"], "values.abc" => ["required"]}}
               )
    end

    test "a list of messages is a 422 joined into detail" do
      assert {422, %{"errors" => errors}} = render({:error, ["a is bad", "b is bad"]})
      assert errors == %{"detail" => "a is bad; b is bad"}
    end
  end

  test "interpolate/1 fills every placeholder it has a value for" do
    assert Problem.interpolate({"between %{min} and %{max}", min: 1, max: 5}) == "between 1 and 5"
    assert Problem.interpolate({"keeps %{unknown}", []}) == "keeps %{unknown}"
    assert Problem.interpolate({"is %{value}", value: ~D[2026-01-01]}) == "is ~D[2026-01-01]"
  end
end
