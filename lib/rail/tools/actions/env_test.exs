defmodule Rail.Tools.Actions.EnvTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "env/0 and env/1 return merged environment map" do
    env0 = Tools.env()
    assert Map.has_key?(env0, "PATH")
    assert byte_size(env0["PATH"]) > 0

    env1 = Tools.env(%{"FOO" => "bar", "NUM" => 42})
    assert env1["FOO"] == "bar"
    assert env1["NUM"] == "42"
    assert env1["PATH"] == env0["PATH"]

    env_override = Tools.env(%{"PATH" => "/custom/override"})
    assert env_override["PATH"] == "/custom/override"

    assert Tools.env(nil) == env0
  end
end
