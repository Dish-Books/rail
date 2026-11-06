defmodule Rail.Tools.Utils.EnvTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.Env

  test "env/0 and env/1 return merged environment map" do
    env0 = env()
    assert Map.has_key?(env0, "PATH")
    assert byte_size(env0["PATH"]) > 0

    env1 = env(%{"FOO" => "bar", "NUM" => 42})
    assert env1["FOO"] == "bar"
    assert env1["NUM"] == "42"
    assert env1["PATH"] == env0["PATH"]

    env_override = env(%{"PATH" => "/custom/override"})
    assert env_override["PATH"] == "/custom/override"

    assert env(nil) == env0
  end

  test "env/1 tells mise never to install a missing tool on its own, unless asked otherwise" do
    assert %{
             "MISE_AUTO_INSTALL" => "false",
             "MISE_EXEC_AUTO_INSTALL" => "false",
             "MISE_NOT_FOUND_AUTO_INSTALL" => "false",
             "MISE_TASK_RUN_AUTO_INSTALL" => "false"
           } = env()

    assert env(%{"MISE_AUTO_INSTALL" => "true"})["MISE_AUTO_INSTALL"] == "true"
  end

  describe "Rail's own configuration" do
    # Named for this module alone, so no other async test sees it, and on no list:
    # whatever Rail's environment carries that a tool does not read stays out.
    @var "ENV_TEST_UNLISTED_SECRET"

    setup do
      System.put_env(@var, "secret")
      on_exit(fn -> System.delete_env(@var) end)
    end

    test "env/1 leaves it out unless asked for it" do
      refute Map.has_key?(env(), @var)
      assert env(%{@var => "given"})[@var] == "given"
    end

    test "env_list/2 unsets it in the child" do
      assert {@var, nil} in env_list(%{}, nil)
      assert {@var, false} in env_list(%{}, false)
      assert {@var, "given"} in env_list(%{@var => "given"}, false)
      refute {@var, false} in env_list(%{@var => "given"}, false)

      assert {"[unset]\n", 0} = System.cmd("sh", ["-c", ~s(echo "[${#{@var}-unset}]")], env: env_list(%{}, nil))
    end
  end

  describe "the secrets and settings Rail's .env and release set" do
    setup do
      # Slack's and the tunnel's leaked once a denylist kept by hand missed them.
      vars = [
        "CLOAK_KEY_V1",
        "DATABASE_URL",
        "ECTO_IPV6",
        "ENABLE_GOTH",
        "GITHUB_APP_ID",
        "GITHUB_APP_PRIVATE_KEY",
        "GITHUB_CLIENT_ID",
        "GITHUB_CLIENT_SECRET",
        "GITHUB_WEBHOOK_SECRET",
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
        "RAIL_ENV_TEST_SETTING",
        "RELEASE_ENV_TEST_SETTING",
        "SECRET_KEY_BASE",
        "SLACK_CLIENT_ID",
        "SLACK_CLIENT_SECRET",
        "TUNNEL_TOKEN"
      ]

      previous = Map.new(vars, &{&1, System.get_env(&1)})
      Enum.each(vars, &System.put_env(&1, "secret"))

      on_exit(fn ->
        Enum.each(previous, fn
          {var, nil} -> System.delete_env(var)
          {var, value} -> System.put_env(var, value)
        end)
      end)

      %{vars: vars}
    end

    test "are never passed to a tool", %{vars: vars} do
      child = env()
      list = env_list(%{}, false)

      for var <- vars do
        refute Map.has_key?(child, var)
        assert {var, false} in list
      end
    end
  end

  describe "what the tools on the machine read" do
    # Named for this module alone; HOME and the like are already set.
    @tool_vars %{"GIT_ENV_TEST" => "git", "LC_ENV_TEST" => "lc", "MISE_ENV_TEST" => "mise", "XDG_ENV_TEST" => "xdg"}

    setup do
      System.put_env(@tool_vars)
      on_exit(fn -> Enum.each(Map.keys(@tool_vars), &System.delete_env/1) end)
    end

    test "passes through" do
      child = env()
      list = env_list(%{}, false)

      assert child["HOME"] == System.get_env("HOME")
      assert child["TMPDIR"] == System.get_env("TMPDIR")

      for {var, value} <- @tool_vars do
        assert child[var] == value
        assert {var, value} in list
      end
    end
  end
end
