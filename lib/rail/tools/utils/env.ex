defmodule Rail.Tools.Utils.Env do
  @moduledoc false

  import Rail.Tools.Utils.MergedPath

  # Rail's own configuration, which is no business of the tools it runs. An agent
  # or CI command in a project's worktree that inherited MIX_ENV=prod and Rail's
  # DATABASE_URL set out to create rail_prod on its first `mix test`, and every
  # one of them could read the GitHub App's private key.
  @app_vars [
    "CLOAK_KEY_V1",
    "DATABASE_URL",
    "ECTO_IPV6",
    "ENABLE_GOTH",
    "GITHUB_APP_ID",
    "GITHUB_APP_PRIVATE_KEY",
    "GITHUB_CLIENT_ID",
    "GITHUB_CLIENT_SECRET",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "GOOGLE_APPLICATION_CREDENTIALS_JSON",
    "LINEAR_CLIENT_ID",
    "LINEAR_CLIENT_SECRET",
    "MIX_ENV",
    "PHX_HOST",
    "PHX_SERVER",
    "POOL_SIZE",
    "PORT",
    "POSTHOG_API_KEY",
    "SECRET_KEY_BASE"
  ]
  @app_prefixes ["RAIL_", "RELEASE_"]

  # A missing tool fails where it is asked for. Left to install it, mise compiles
  # Erlang inside a sandbox's memory cap, with a build cache that is thrown away.
  @mise_vars %{
    "MISE_AUTO_INSTALL" => "false",
    "MISE_EXEC_AUTO_INSTALL" => "false",
    "MISE_NOT_FOUND_AUTO_INSTALL" => "false",
    "MISE_TASK_RUN_AUTO_INSTALL" => "false"
  }

  @doc """
  Builds the environment a tool process should run with: the current
  environment without Rail's own configuration, with the tool PATH and mise
  told never to install a missing tool on its own, plus any extra variables.
  """
  def env(extra \\ %{})

  def env(nil), do: env(%{})

  def env(extra) when is_map(extra) or is_list(extra) do
    base =
      System.get_env()
      |> Map.reject(fn {key, _value} -> app_var?(key) end)
      |> Map.merge(@mise_vars)
      |> Map.put("PATH", merged_path())

    Enum.reduce(extra, base, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value))
    end)
  end

  @doc """
  Returns `env/1` as a list for the `:env` option of `System.cmd/3` or
  `Port.open/2`. Both only add to the BEAM's own environment, so each of Rail's
  variables that `extra` does not set is listed with `unset` (`nil` for
  `System.cmd/3`, `false` for `Port.open/2`) to leave it out of the child.
  """
  def env_list(extra, unset) when unset in [nil, false] do
    env = env(extra)

    unsets =
      for {key, _value} <- System.get_env(), app_var?(key), not Map.has_key?(env, key), do: {key, unset}

    Map.to_list(env) ++ unsets
  end

  defp app_var?(key), do: key in @app_vars or String.starts_with?(key, @app_prefixes)
end
