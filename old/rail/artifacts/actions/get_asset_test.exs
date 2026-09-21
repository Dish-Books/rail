defmodule Rail.Artifacts.Actions.GetAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Scope

  describe "get_asset/3" do
    test "rejects unauthorized scope" do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.get_asset(scope, "demo", "ast_1")
    end

    test "looks up demo asset by linear_asset_id" do
      scope = Scope.user_scope()

      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_dmo_lookup",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          segments: [
            %{
              criterion_index: 1,
              criterion: "Check A",
              outcome: :recorded,
              frames: [
                %{
                  url: "https://uploads.linear.app/asset/frame_1.png",
                  linear_asset_id: "lin_frame_1",
                  hold_ms: 1000
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      assert {:ok, %{url: "https://uploads.linear.app/asset/frame_1.png", task_id: "tsk_dmo_lookup"}} =
               Artifacts.get_asset(scope, "demo", "lin_frame_1")

      assert {:error, :not_found} = Artifacts.get_asset(scope, "demo", "missing_frame")
    end

    test "an unknown kind is not found" do
      assert {:error, :not_found} = Artifacts.get_asset(Scope.for_system(), "unknown_kind", "shot_1.png")
    end
  end
end
