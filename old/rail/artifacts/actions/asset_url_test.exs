defmodule Rail.Artifacts.Actions.AssetUrlTest do
  use ExUnit.Case, async: true

  describe "asset_url/2" do
    test "constructs local proxy path" do
      assert Rail.Artifacts.asset_url(:demo, "ast_123") == "/assets/demo/ast_123"
      assert Rail.Artifacts.asset_url(:qa, "shot_1") == "/assets/qa/shot_1"
    end
  end
end
