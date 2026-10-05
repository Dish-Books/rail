defmodule Rail.Tools.ClaudeTest do
  use ExUnit.Case, async: true

  alias Rail.Tools.Claude
  alias Rail.Tools.Schemas.Backend

  setup do
    %{backend: %Backend{id: "bkd_claude_probe", name: :claude, executable_path: System.find_executable("sh")}}
  end

  test "reports not_configured unless the path is a runnable file" do
    assert %{status: :not_configured, unavailable_reason: "Executable not found at ''"} =
             Claude.probe(%Backend{name: :claude, oauth_token: "tok"})

    missing = %Backend{name: :claude, executable_path: "/non/existent/claude"}

    assert %{
             name: :claude,
             status: :not_configured,
             unavailable_reason: "Executable not found at '/non/existent/claude'"
           } = Claude.probe(missing)

    assert %{status: :not_configured} = Claude.probe(%Backend{name: :claude, executable_path: System.tmp_dir!()})

    not_executable = Path.join(System.tmp_dir!(), "claude_probe_#{System.unique_integer([:positive])}")
    File.write!(not_executable, "#!/bin/sh\n")
    File.chmod!(not_executable, 0o644)
    on_exit(fn -> File.rm(not_executable) end)

    assert %{status: :not_configured} = Claude.probe(%Backend{name: :claude, executable_path: not_executable})
  end

  test "is signed out without a token, saying how to get one", %{backend: backend} do
    assert %{status: :signed_out, account_label: nil, usage: [], unavailable_reason: reason} = Claude.probe(backend)
    assert reason =~ "No token. Run `claude setup-token`"
  end

  test "is ready with a token, with no account or quota to report", %{backend: backend} do
    assert %{
             name: :claude,
             status: :ready,
             account_label: "Long-lived token",
             account_detail: nil,
             usage: [],
             fetched_at: nil,
             unavailable_reason: nil
           } = Claude.probe(%{backend | oauth_token: "tok"})
  end

  test "stays signed out with a token Claude rejected", %{backend: backend} do
    rejected = %{backend | oauth_token: "tok", session_lost_at: DateTime.utc_now()}

    assert %{status: :signed_out, unavailable_reason: reason} = Claude.probe(rejected)
    assert reason =~ "Claude rejected the token."
  end
end
