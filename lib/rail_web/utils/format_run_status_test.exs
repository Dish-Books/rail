defmodule RailWeb.Utils.FormatRunStatusTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatRunStatus

  test "nothing to say about no status" do
    assert format_run_status(nil) == ""
    assert format_run_status("") == ""
  end

  test "a one-word status reads as itself" do
    assert format_run_status(:running) == "running"
  end

  test "an underscored status reads as lowerCamel" do
    assert format_run_status(:blocked_on_input) == "blockedOnInput"
    assert format_run_status("adopted_dead") == "adoptedDead"
  end
end
