defmodule Rail.Tools.Actions.RefreshUsageTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  test "probes each backend at its configured path and upserts what it reports" do
    # The path each probe runs comes off the backend row, so both must exist.
    claude = System.find_executable("sh")
    agy = System.find_executable("cat")

    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: claude}))
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :agy, executable_path: agy}))

    stub(Tools, :run, fn
      ^claude, _args, _opts ->
        {~s({"loggedIn":true,"email":"claude@example.com","subscriptionType":"Pro"}), 0}

      ^agy, _args, _opts ->
        {~s({"status":"SUCCESS"}), 0}
    end)

    agy_log = "2026-09-09T15:00:00.123Z INFO [Auth] applyAuthResult: email=agy@example.com, authMethod=oauth\n"

    claude_config =
      ~s({"cachedUsageUtilization":{"fetchedAtMs":1725894000000,"utilization":{"limits":[) <>
        ~s({"group":"session","kind":"session","percent":20.0,"resets_at":"2026-09-10T12:00:00Z"}) <>
        ~s(]}}})

    stub(File, :read, fn path ->
      if String.ends_with?(path, "agy_scratch.log"), do: {:ok, agy_log}, else: {:ok, claude_config}
    end)

    assert {:ok,
            [
              %Backend{id: claude_id, name: :claude, account_label: "claude@example.com", status: :ready},
              %Backend{id: agy_id, name: :agy, account_label: "agy@example.com", status: :ready}
            ]} = Tools.refresh_usage()

    # Refreshing again updates the same rows rather than inserting new ones.
    assert {:ok, [%Backend{id: ^claude_id}, %Backend{id: ^agy_id}]} = Tools.refresh_usage()

    # The config the user owns survives a refresh.
    assert %Backend{executable_path: ^claude, status: :ready} = Repo.get!(Backend, claude_id)
  end

  test "records that a configured backend's binary has gone missing" do
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/non/existent/claude"}))
    Repo.insert!(Backend.changeset(%Backend{}, %{name: :agy, executable_path: "/non/existent/agy"}))

    claude_reason = "Executable not found at '/non/existent/claude'"
    agy_reason = "Executable not found at '/non/existent/agy'"

    assert {:ok,
            [
              %Backend{name: :claude, status: :not_configured, unavailable_reason: ^claude_reason},
              %Backend{name: :agy, status: :not_configured, unavailable_reason: ^agy_reason}
            ]} = Tools.refresh_usage()
  end

  test "skips a backend that has not been configured at all" do
    assert {:ok, []} = Tools.refresh_usage()

    Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: "/non/existent/claude"}))

    assert {:ok, [%Backend{name: :claude, status: :not_configured}]} = Tools.refresh_usage()
  end
end
