defmodule Rail.Artifacts.Actions.ReadQaReportTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts
  alias Rail.Scope
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_read_qa"

  setup do
    dir = Path.join(@tmp_base, "task_#{System.unique_integer([:positive])}")
    qa_dir = Path.join(dir, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, qa_dir: qa_dir}
  end

  describe "read_qa_report/3" do
    test "rejects unauthorized scope", %{dir: dir} do
      scope = %Scope{user: nil, system: false}
      assert {:error, :not_authorized} = Artifacts.read_qa_report(scope, dir)
    end

    test "reads the manifest out of the scratch directory's qa/", %{dir: dir, qa_dir: qa_dir} do
      scope = Scope.for_system()
      ArtifactHelpers.write_qa_manifest(qa_dir)

      assert {:ok, %{commit: "abc1234", rows: [_row]}} = Artifacts.read_qa_report(scope, dir)
    end

    # The scratch directory is the only place a report is looked for: one written
    # into the worktree instead is a report Rail never saw.
    test "ignores a manifest left in the worktree's .rail/qa", %{dir: dir} do
      scope = Scope.for_system()
      rail_qa = Path.join([dir, ".rail", "qa"])
      File.mkdir_p!(rail_qa)
      ArtifactHelpers.write_qa_manifest(rail_qa)

      assert {:error, msg} = Artifacts.read_qa_report(scope, dir)
      assert msg =~ "QA manifest not found"
    end

    test "returns validation failure when manifest is invalid", %{dir: dir, qa_dir: qa_dir} do
      scope = Scope.for_system()
      File.write!(Path.join(qa_dir, "manifest.json"), "{bad_json")

      assert {:error, msg} = Artifacts.read_qa_report(scope, dir)
      assert msg =~ "Failed to parse QA manifest"
    end

    test "returns error when manifest does not exist" do
      scope = Scope.for_system()
      assert {:error, msg} = Artifacts.read_qa_report(scope, "/nonexistent/scratch")
      assert msg =~ "QA manifest not found"
    end
  end
end
