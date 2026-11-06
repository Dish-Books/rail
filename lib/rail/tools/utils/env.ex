defmodule Rail.Tools.Utils.Env do
  @moduledoc false

  import Rail.Tools.Utils.MergedPath

  # Rail's environment is Rail's configuration, which is no business of the tools
  # it runs: compose loads all of Rail's .env into it. An agent or CI command that
  # inherited MIX_ENV=prod and Rail's DATABASE_URL set out to create rail_prod on
  # its first `mix test`, and a denylist kept by hand let through the Slack app
  # and tunnel credentials added after it was written. So a tool gets only what
  # this machine's tools read, named here, and what Rail sets for it on purpose.
  @tool_vars [
    "COLORTERM",
    "DISABLE_AUTOUPDATER",
    "ERL_AFLAGS",
    "ERL_FLAGS",
    "ERL_ZFLAGS",
    "HOME",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "LANG",
    "LANGUAGE",
    "LOGNAME",
    "NO_PROXY",
    "SHELL",
    "SSH_AUTH_SOCK",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TERM",
    "TMPDIR",
    "TZ",
    "USER",
    "https_proxy",
    "http_proxy",
    "no_proxy"
  ]
  @tool_prefixes ["GIT_", "LC_", "MISE_", "XDG_"]

  # A missing tool fails where it is asked for. Left to install it, mise compiles
  # Erlang inside a sandbox, with a build cache that is thrown away.
  @mise_vars %{
    "MISE_AUTO_INSTALL" => "false",
    "MISE_EXEC_AUTO_INSTALL" => "false",
    "MISE_NOT_FOUND_AUTO_INSTALL" => "false",
    "MISE_TASK_RUN_AUTO_INSTALL" => "false"
  }

  @doc """
  Builds the environment a tool process should run with: what the tools on this
  machine read from the current environment, with the tool PATH and mise told
  never to install a missing tool on its own, plus any extra variables. Nothing
  else of Rail's own reaches it.
  """
  def env(extra \\ %{})

  def env(nil), do: env(%{})

  def env(extra) when is_map(extra) or is_list(extra) do
    base =
      System.get_env()
      |> Map.filter(fn {key, _value} -> tool_var?(key) end)
      |> Map.merge(@mise_vars)
      |> Map.put("PATH", merged_path())

    Enum.reduce(extra, base, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value))
    end)
  end

  @doc """
  Returns `env/1` as a list for the `:env` option of `System.cmd/3` or
  `Port.open/2`. Both only add to the BEAM's own environment, so each variable
  of Rail's that `env/1` leaves out is listed with `unset` (`nil` for
  `System.cmd/3`, `false` for `Port.open/2`) to leave it out of the child.
  """
  def env_list(extra, unset) when unset in [nil, false] do
    env = env(extra)
    unsets = for {key, _value} <- System.get_env(), not Map.has_key?(env, key), do: {key, unset}

    Map.to_list(env) ++ unsets
  end

  defp tool_var?(key), do: key in @tool_vars or String.starts_with?(key, @tool_prefixes)
end
