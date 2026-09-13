defmodule Rail.Tools.AgyTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Agy
  alias Rail.Tools.Schemas.Backend

  @usage_ok ~s({"status":"SUCCESS","command":{"data":{"groups":[) <>
              ~s({"name":"Gemini Models","buckets":[) <>
              ~s({"window":"5h","remaining_fraction":0.85,"reset_time":"2026-09-09T20:00:00Z"},) <>
              ~s({"window":"weekly","remaining_fraction":0.6,"reset_time":"2026-09-16T20:00:00Z"},) <>
              ~s({"window":"daily","name":"Named Bucket","remaining_fraction":0.5},) <>
              ~s({"name":"Only Name","remaining_fraction":null},{}) <>
              ~s(]},{"buckets":[]}]}}})

  @auth_log "2026-09-09T15:00:00.123Z INFO [Auth] applyAuthResult: email=agy@example.com, authMethod=oauth\n"

  setup do
    # A real executable, so the path check is the real one; what it would have
    # run is what gets stubbed.
    %{backend: %Backend{name: :agy, executable_path: System.find_executable("sh")}}
  end

  test "reports not_configured unless the path is a runnable file" do
    assert %{status: :not_configured, unavailable_reason: "Executable not found at ''"} =
             Agy.probe(%Backend{name: :agy})

    missing = %Backend{name: :agy, executable_path: "/non/existent/agy"}

    assert %{
             name: :agy,
             status: :not_configured,
             unavailable_reason: "Executable not found at '/non/existent/agy'"
           } = Agy.probe(missing)

    assert %{status: :not_configured} = Agy.probe(%Backend{name: :agy, executable_path: System.tmp_dir!()})

    not_executable = Path.join(System.tmp_dir!(), "agy_probe_#{System.unique_integer([:positive])}")
    File.write!(not_executable, "#!/bin/sh\n")
    File.chmod!(not_executable, 0o644)
    on_exit(fn -> File.rm(not_executable) end)

    assert %{status: :not_configured} = Agy.probe(%Backend{name: :agy, executable_path: not_executable})
  end

  test "reports unavailable when the usage command times out or fails to spawn", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {:error, :timeout} end)
    assert %{status: :unavailable, unavailable_reason: "Usage check timed out after 20s"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {:error, :enoent} end)
    assert %{status: :unavailable, unavailable_reason: "Failed to execute probe: :enoent"} = Agy.probe(backend)
  end

  test "reads a non-zero exit as signed_out only when the CLI says so", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {"Error: NOT_LOGGED_IN to service", 1} end)
    assert %{status: :signed_out, unavailable_reason: "CLI exited with code 1"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {"Internal command failure", 2} end)
    assert %{status: :unavailable, unavailable_reason: "CLI exited with code 2"} = Agy.probe(backend)
  end

  test "reports unavailable when the usage output is not JSON", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {"not json", 0} end)

    assert %{status: :unavailable, unavailable_reason: reason} = Agy.probe(backend)
    assert reason =~ "Failed to parse usage JSON"
  end

  test "reads a non-SUCCESS status as signed_out when it reads as a login problem", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"NOT_LOGGED_IN"}), 0} end)
    assert %{status: :signed_out, unavailable_reason: "NOT_LOGGED_IN"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"ERROR","response":"Please log in first"}), 0} end)
    assert %{status: :signed_out, unavailable_reason: "Please log in first"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"ERROR","response":"You are not logged in"}), 0} end)
    assert %{status: :signed_out, unavailable_reason: "You are not logged in"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"ERROR","response":"Something broke"}), 0} end)
    assert %{status: :unavailable, unavailable_reason: "Something broke"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"ERROR","response":""}), 0} end)
    assert %{status: :unavailable, unavailable_reason: "ERROR"} = Agy.probe(backend)

    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"response":null}), 0} end)
    assert %{status: :unavailable, unavailable_reason: "Unknown error"} = Agy.probe(backend)
  end

  test "reports ready with the account scraped from the log and buckets labelled", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {@usage_ok, 0} end)
    stub(File, :read, fn _path -> {:ok, @auth_log} end)

    before = DateTime.utc_now()

    assert %{
             name: :agy,
             status: :ready,
             account_label: "agy@example.com",
             account_detail: "oauth",
             unavailable_reason: nil,
             fetched_at: fetched_at,
             usage: [gemini, unnamed]
           } = Agy.probe(backend)

    assert DateTime.compare(fetched_at, before) in [:eq, :gt]

    assert %{name: "Gemini Models", count: 5, details: %{"windows" => windows}} = gemini

    assert [
             %{"label" => "5-Hour", "remaining_percent" => 85.0, "resets_at" => "2026-09-09T20:00:00Z"},
             %{"label" => "Weekly", "remaining_percent" => 60.0},
             %{"label" => "Named Bucket", "remaining_percent" => 50.0},
             %{"label" => "Only Name", "remaining_percent" => nil},
             %{"label" => "Limit", "remaining_percent" => nil}
           ] = windows

    assert %{name: "Limits", count: 0, details: %{"windows" => []}} = unnamed
  end

  test "falls back to an unknown account when the log is missing or nameless", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"SUCCESS"}), 0} end)

    stub(File, :read, fn _path -> {:error, :enoent} end)
    assert %{status: :ready, account_label: "Account unknown", account_detail: nil, usage: []} = Agy.probe(backend)

    blank_identity = "INFO [Auth] applyAuthResult: email= , authMethod= \n"
    stub(File, :read, fn _path -> {:ok, blank_identity} end)
    assert %{account_label: "Account unknown", account_detail: nil} = Agy.probe(backend)
  end

  test "treats groups that are not a list as no groups at all", %{backend: backend} do
    stub(Tools, :run, fn _exe, _args, _opts -> {~s({"status":"SUCCESS","command":{"data":{"groups":"nope"}}}), 0} end)
    stub(File, :read, fn _path -> {:ok, @auth_log} end)

    assert %{status: :ready, usage: []} = Agy.probe(backend)
  end

  test "cleans up the scratch directory it gave the CLI", %{backend: backend} do
    test_pid = self()

    stub(Tools, :run, fn _exe, args, opts ->
      send(test_pid, {:ran, args, opts[:cd]})
      {~s({"status":"SUCCESS"}), 0}
    end)

    stub(File, :read, fn _path -> {:ok, @auth_log} end)

    assert %{status: :ready} = Agy.probe(backend)
    assert_received {:ran, ["-p", "/usage", "--output-format", "json", "--log-file", scratch_log], temp_dir}
    assert scratch_log == Path.join(temp_dir, "agy_scratch.log")
    refute File.exists?(temp_dir)
  end
end
