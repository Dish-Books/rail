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

  describe "the Google credentials Goth reads" do
    setup do
      vars = ["GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_APPLICATION_CREDENTIALS_JSON", "ENABLE_GOTH"]
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
end
