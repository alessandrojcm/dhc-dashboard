defmodule Dhc.Auth.CapabilitiesTest do
  use Dhc.DataCase, async: true

  alias Dhc.Auth.Capabilities

  import Dhc.AuthFixtures

  @self "11111111-1111-1111-1111-111111111111"
  @other "22222222-2222-2222-2222-222222222222"

  @every_role ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach member)

  @officers ~w(admin president committee_coordinator)
  @member_administrators ~w(admin president treasurer committee_coordinator sparring_coordinator workshop_coordinator beginners_coordinator quartermaster pr_manager volunteer_coordinator research_coordinator coach)

  # Capability → the only roles that hold it without resource context, plus
  # whether the resource owner is also granted it. Changing a role
  # assignment must show up as exactly one intentional diff here.
  @policy %{
    "beginners.waitlist.manage":
      {~w(admin president committee_coordinator beginners_coordinator), false},
    "beginners.waitlist.toggle": {@officers, false},
    "discord.assignments.manage": {@member_administrators, false},
    "discord.doctor.use": {@officers, false},
    "inventory.manage": {~w(quartermaster admin president), false},
    "inventory.catalog.read": {~w(member), false},
    "inventory.loans.own.read": {~w(member), false},
    "member_announcements.send": {@officers, false},
    "members.directory.read": {@member_administrators, false},
    "members.invite": {@officers, false},
    "members.profile.read": {@member_administrators, true},
    "members.profile.update": {@member_administrators, true},
    "members.roles.edit": {~w(admin president), false},
    "members.settings.edit": {@officers, false},
    "membership.reactivate": {~w(admin president treasurer committee_coordinator), false},
    "training_announcements.manage":
      {~w(admin president committee_coordinator sparring_coordinator coach), false},
    "workshops.manage": {~w(workshop_coordinator president admin), false},
    "workshops.own.read": {~w(member), false}
  }

  defp session(roles, opts \\ []) do
    %{
      principal: %{id: Keyword.get(opts, :id, @self)},
      roles: roles,
      is_active: Keyword.get(opts, :is_active, true)
    }
  end

  test "the policy table covers exactly the registry" do
    assert Enum.sort(Map.keys(@policy)) == Capabilities.all()
  end

  test "the OpenAPI AuthCapability enum is the registry" do
    {:ok, spec} =
      :dhc |> Application.app_dir("priv/api/openapi.yaml") |> YamlElixir.read_from_file()

    assert Enum.sort(spec["components"]["schemas"]["AuthCapability"]["enum"]) ==
             Enum.map(Capabilities.all(), &Atom.to_string/1)
  end

  for {capability, {allowed, owner?}} <- @policy do
    describe "#{capability}" do
      @capability capability
      @allowed allowed
      @owner owner?

      test "is held by exactly its role set" do
        for role <- @every_role do
          assert Capabilities.can?(session([role]), @capability) == role in @allowed,
                 "#{role} on #{@capability}"
        end
      end

      test "owner rule" do
        assert Capabilities.owner_scoped?(@capability) == @owner
        own = %{owner_principal_id: @self}
        other = %{owner_principal_id: @other}

        assert Capabilities.can?(session(["member"]), @capability, own) ==
                 (@owner or "member" in @allowed)

        expected_denial = if @owner, do: {:error, :not_found}, else: {:error, :forbidden}

        unless "member" in @allowed do
          assert Capabilities.authorize(session(["member"]), @capability, other) ==
                   expected_denial

          assert Capabilities.authorize(session(["member"]), @capability) == expected_denial
        end
      end

      test "an inactive session holds nothing" do
        assert Capabilities.authorize(session(@allowed, is_active: false), @capability) ==
                 {:error, :inactive}
      end
    end
  end

  describe "for_roles/1" do
    test "lists the wire names of every capability the roles hold" do
      assert Capabilities.for_roles(["member"]) ==
               ~w(inventory.catalog.read inventory.loans.own.read workshops.own.read)

      assert Capabilities.for_roles([]) == []

      assert "inventory.manage" in Capabilities.for_roles(["member", "quartermaster"])
      # Owner-scoped capabilities are listed only when a role grants them.
      refute "members.profile.read" in Capabilities.for_roles(["member"])
    end
  end

  describe "authorize/3" do
    test "nil capability admits any active session" do
      assert Capabilities.authorize(session([]), nil) == :ok
      assert Capabilities.authorize(session([], is_active: false), nil) == {:error, :inactive}
    end

    test "unknown capabilities raise" do
      assert_raise ArgumentError, fn -> Capabilities.can?(session(["admin"]), :"nope.nope") end
    end
  end

  describe "holds?/2" do
    test "reads role rows, regardless of profile activity" do
      holder = principal_fixture()
      plain = principal_fixture()

      Repo.insert_all("user_roles", [
        [principal_id: Ecto.UUID.dump!(holder.id), role: "coach"],
        [principal_id: Ecto.UUID.dump!(plain.id), role: "member"]
      ])

      assert Capabilities.holds?(holder.id, :"discord.assignments.manage")
      refute Capabilities.holds?(holder.id, :"inventory.manage")
      refute Capabilities.holds?(plain.id, :"discord.assignments.manage")
    end
  end

  describe "principal_ids_with/2" do
    test "includes an active holder and omits an inactive or profile-less one" do
      %{principal_id: active} = Dhc.MemberFixtures.member_fixture(%{is_active: true})
      %{principal_id: inactive} = Dhc.MemberFixtures.member_fixture(%{is_active: false})
      leftover = principal_fixture()

      Repo.insert_all("user_roles", [
        [principal_id: Ecto.UUID.dump!(active), role: "quartermaster"],
        [principal_id: Ecto.UUID.dump!(inactive), role: "admin"],
        [principal_id: Ecto.UUID.dump!(leftover.id), role: "president"]
      ])

      assert Capabilities.principal_ids_with(:"inventory.manage") == [active]
      assert Capabilities.principal_ids_with(:"inventory.manage", except: active) == []
    end
  end
end
