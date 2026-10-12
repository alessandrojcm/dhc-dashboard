defmodule Dhc.Discord.DoctorKickTest do
  use ExUnit.Case, async: true

  alias Dhc.Discord.DoctorKick

  defp row(bucket, attrs \\ []) do
    Map.merge(
      %{bucket: bucket, bot: false, protected: false, membership_status: nil},
      Map.new(attrs)
    )
  end

  describe "decide/1" do
    test "linked inactive and unrecognized accounts can be kicked in bulk" do
      assert DoctorKick.decide(row(:linked_inactive, membership_status: :inactive)) ==
               {:bulk, nil}

      assert DoctorKick.decide(row(:unrecognized)) == {:bulk, nil}
    end

    test "a pending link can be kicked only on its own" do
      assert DoctorKick.decide(row(:pending_link, membership_status: :inactive)) ==
               {:single, nil}
    end

    test "refuses each unsafe account with a staff-facing reason" do
      assert DoctorKick.decide(row(:unrecognized, bot: true)) == {:none, "Bot account"}

      assert DoctorKick.decide(row(:linked_inactive, protected: true)) ==
               {:none, "Protected member"}

      assert DoctorKick.decide(row(:pending_link, membership_status: :paused)) ==
               {:none, "Paused member"}

      assert DoctorKick.decide(row(:linked_active, membership_status: :active)) ==
               {:none, "Active member"}
    end

    test "protection outranks every later refusal" do
      assert DoctorKick.decide(row(:linked_active, protected: true, membership_status: :paused)) ==
               {:none, "Protected member"}
    end
  end

  describe "decide/2 for a kick request" do
    test "refuses a pending link among several targets" do
      assert DoctorKick.decide(row(:pending_link), multiple_targets?: true) ==
               {:none, "Pending links can only be kicked one at a time"}
    end

    test "allows a pending link as the only target and bulk rows among several" do
      assert DoctorKick.decide(row(:pending_link), multiple_targets?: false) == {:single, nil}
      assert DoctorKick.decide(row(:unrecognized), multiple_targets?: true) == {:bulk, nil}
    end
  end

  describe "audit reasons" do
    test "names the bucket with the page's label, never its identifier" do
      assert DoctorKick.bucket_label(:linked_inactive) == "Linked – inactive"
      assert DoctorKick.bucket_label(:pending_link) == "Pending link"
      assert DoctorKick.bucket_label(:unrecognized) == "Unrecognized"
    end

    test "builds the prefix for the requesting admin for every kickable bucket" do
      assert DoctorKick.reason_prefixes("Aoife Byrne") == %{
               linked_inactive: "DHC Doctor — Aoife Byrne: Linked – inactive",
               pending_link: "DHC Doctor — Aoife Byrne: Pending link",
               unrecognized: "DHC Doctor — Aoife Byrne: Unrecognized"
             }
    end

    test "appends a trimmed note and ignores a blank one" do
      assert DoctorKick.audit_reason("Aoife Byrne", :linked_inactive, "  Left the club  ") ==
               "DHC Doctor — Aoife Byrne: Linked – inactive — Left the club"

      assert DoctorKick.audit_reason("Aoife Byrne", :unrecognized, "   ") ==
               "DHC Doctor — Aoife Byrne: Unrecognized"

      assert DoctorKick.audit_reason("Aoife Byrne", :pending_link, nil) ==
               "DHC Doctor — Aoife Byrne: Pending link"
    end
  end
end
