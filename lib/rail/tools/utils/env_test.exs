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

  describe "Rail's own configuration" do
    # Named for this module alone, so no other async test sees it.
    @var "RAIL_ENV_TEST_SECRET"

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
end
