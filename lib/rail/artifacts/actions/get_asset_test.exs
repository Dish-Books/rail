defmodule Rail.Artifacts.Actions.GetAssetTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.Design
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Scope

  describe "get_asset/3" do
    test "rejects unauthorized scope" do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.get_asset(scope, "demo", "ast_1")
    end

    test "looks up design asset by linear_asset_id and key" do
      scope = Scope.for_system()

      {:ok, _design} =
        %Design{}
        |> Design.changeset(%{
          task_id: "tsk_dsg_lookup",
          canvas_url: "https://canvas.example.com/1",
          directions: [
            %{
              key: "dir_k1",
              title: "Dir 1",
              notes: "Notes",
              still_url: "https://uploads.linear.app/asset/dir1.png",
              linear_asset_id: "lin_dsg_1"
            }
          ]
        })
        |> Repo.insert()

      assert {:ok, %{url: "https://uploads.linear.app/asset/dir1.png", task_id: "tsk_dsg_lookup"}} =
               Artifacts.get_asset(scope, "design", "lin_dsg_1")

      assert {:ok, %{url: "https://uploads.linear.app/asset/dir1.png"}} =
               Artifacts.get_asset(scope, :design, "dir_k1")

      assert {:error, :not_found} = Artifacts.get_asset(scope, "design", "missing_asset")
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

    test "looks up qa asset by name or url" do
      scope = Scope.for_system()

      {:ok, _qa} =
        %QaReport{}
        |> QaReport.changeset(%{
          task_id: "tsk_qar_lookup",
          session: %{},
          rows: [
            %{
              id: "c1",
              check: "Check",
              result: :pass,
              severity: :blocker,
              artifacts: [
                %{
                  name: "shot_1.png",
                  kind: :image,
                  url: "https://uploads.linear.app/asset/shot_1.png"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      assert {:ok, %{url: "https://uploads.linear.app/asset/shot_1.png", task_id: "tsk_qar_lookup"}} =
               Artifacts.get_asset(scope, "qa", "shot_1.png")

      assert {:ok, %{url: "https://uploads.linear.app/asset/shot_1.png"}} =
               Artifacts.get_asset(scope, "qa_report", "shot_1.png")

      assert {:error, :not_found} = Artifacts.get_asset(scope, "qa", "missing_shot.png")

      assert {:error, :not_found} = Artifacts.get_asset(scope, "unknown_kind", "shot_1.png")
    end
  end
end
