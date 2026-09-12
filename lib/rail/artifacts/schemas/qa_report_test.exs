defmodule Rail.Artifacts.Schemas.QaReportTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts.Schemas.QaReport

  describe "changeset/2" do
    test "valid changeset succeeds" do
      attrs = %{
        task_id: "tsk_qa_1",
        run_id: "rr_123",
        commit: "abc1234",
        session: %{"port" => 4000, "url" => "http://localhost:4000"},
        rows: [
          %{
            id: "c1",
            check: "Tests pass",
            result: :pass,
            severity: :blocker,
            artifacts: [
              %{name: "log.txt", kind: :text, text: "output"}
            ]
          }
        ]
      }

      changeset = QaReport.changeset(%QaReport{}, attrs)
      assert changeset.valid?
      assert {:ok, %QaReport{task_id: "tsk_qa_1"}} = Repo.insert(changeset)
    end

    test "requires task_id" do
      changeset = QaReport.changeset(%QaReport{}, %{})
      refute changeset.valid?
      assert %{task_id: [_task_err]} = errors_on(changeset)
    end
  end
end
