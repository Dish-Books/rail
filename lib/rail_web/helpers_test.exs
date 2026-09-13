defmodule RailWeb.HelpersTest do
  use ExUnit.Case, async: true

  import RailWeb.Helpers

  test "every template reaches the formatting through one import" do
    assert format_cost(0.025) == "$0.0250"
    assert format_cost(Decimal.new("1"), "EUR") == "1.0000 EUR"
    assert format_duration(90) == "1m 30s"
    assert format_run_status(:blocked_on_input) == "blockedOnInput"
    assert format_tokens(1_500) == "1.5K"
    assert format_tokens(1, suffix: true) == "1 token"
  end
end
