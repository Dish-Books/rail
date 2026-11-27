defmodule RailTest do
  # Not async: one test sets the app's Cloudflare Access config, which others read.
  use ExUnit.Case, async: false

  # A sandbox mounts this folder read-only, so it must be the one mise itself installs into.
  test "the toolchain a sandbox reads is where mise keeps its data" do
    assert Rail.mise_data_dir() == System.get_env("MISE_DATA_DIR")
  end

  test "the sandbox socket's Access check needs the team's domain and the socket app's tag" do
    config = Application.get_env(:rail, :cloudflare_access, [])
    on_exit(fn -> Application.put_env(:rail, :cloudflare_access, config) end)

    Application.put_env(
      :rail,
      :cloudflare_access,
      Keyword.merge(config, team_domain: "team.cloudflareaccess.com", sandbox_aud: "tag")
    )

    assert Rail.sandbox_access() == %{team_domain: "team.cloudflareaccess.com", aud: "tag"}

    Application.put_env(:rail, :cloudflare_access, Keyword.merge(config, team_domain: nil, sandbox_aud: "tag"))
    assert Rail.sandbox_access() == nil
  end

  # Where `make -C runner build` puts the binaries, so a Docker host run from a checkout finds them.
  test "the runner's binaries are the runner module's build output unless configured" do
    assert Rail.runner_dir() == Path.expand("../runner/dist", Path.dirname(__ENV__.file))
  end
end
