defmodule Rail.Artifacts.Schemas.QaReportTest do
  use Rail.DataCase, async: true

  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.Embeds.QaRow

  describe "changeset/2 and factory/0" do
    test "factory generates valid QA report" do
      report = QaReport.factory()
      assert %QaReport{task_id: "tsk_" <> _rest} = report
      assert [%QaRow{id: "check_1"}] = report.rows
    end

    test "valid changeset succeeds" do
      attrs = %{
        task_id: "tsk_qa_1",
        role_run_id: "rr_123",
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
