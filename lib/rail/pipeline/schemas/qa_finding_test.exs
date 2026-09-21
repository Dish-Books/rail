defmodule Rail.Pipeline.Schemas.QaFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.QaFinding

  @attrs %{
    task_id: "tsk_qaf",
    key: "amount-renders-unrounded",
    title: "The bill total renders as $1234.5",
    check: "A bill's total reads as money on the bill page",
    severity: :major,
    recommendation: :fix,
    status: :open
  }

  test "a finding arrives with nobody having ruled on it, whatever QA recommended" do
    for recommendation <- [:fix, :skip] do
      changeset = QaFinding.changeset(%QaFinding{}, %{@attrs | recommendation: recommendation})

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).decision == nil
    end
  end

  test "a finding says what it is, where it came from and how much it matters" do
    changeset = QaFinding.changeset(%QaFinding{}, %{})

    assert %{
             task_id: ["can't be blank"],
             key: ["can't be blank"],
             title: ["can't be blank"],
             check: ["can't be blank"],
             severity: ["can't be blank"],
             recommendation: ["can't be blank"]
           } = errors_on(changeset)
  end

  # The one column QA may not write. Casting it would re-open everything the
  # human dismissed every time a pass ran again.
  test "QA cannot rule on its own finding" do
    changeset = QaFinding.changeset(%QaFinding{}, Map.put(@attrs, :decision, :skip))

    assert Ecto.Changeset.apply_changes(changeset).decision == nil
  end

  test "a finding is this change's fault unless QA says otherwise" do
    assert Ecto.Changeset.apply_changes(QaFinding.changeset(%QaFinding{}, @attrs)).caused_by_change

    refute Ecto.Changeset.apply_changes(QaFinding.changeset(%QaFinding{}, Map.put(@attrs, :caused_by_change, false))).caused_by_change
  end

  test "evidence is a caption over a file or some text" do
    evidence = %{name: "the total", kind: :query, text: "1234.50"}

    assert QaFinding.changeset(%QaFinding{}, Map.put(@attrs, :evidence, [evidence])).valid?

    refute QaFinding.changeset(%QaFinding{}, Map.put(@attrs, :evidence, [Map.delete(evidence, :text)])).valid?
  end

  # The one string in this application that becomes a filename on a stranger's
  # request.
  test "evidence cannot name a file outside the QA directory" do
    for path <- ["/etc/passwd", "../../etc/passwd", "evidence/../../secrets.txt"] do
      changeset =
        QaFinding.changeset(
          %QaFinding{},
          Map.put(@attrs, :evidence, [%{name: "a shot", kind: :screenshot, path: path}])
        )

      refute changeset.valid?, "#{path} should not be storable"
    end

    assert QaFinding.changeset(
             %QaFinding{},
             Map.put(@attrs, :evidence, [%{name: "a shot", kind: :screenshot, path: "evidence/bill-new.png"}])
           ).valid?
  end

  test "a finding is outstanding only once a human says to fix it" do
    refute QaFinding.outstanding?(%QaFinding{decision: nil})
    refute QaFinding.outstanding?(%QaFinding{decision: :skip})
    refute QaFinding.outstanding?(%QaFinding{decision: :fix, status: :fixed})
    assert QaFinding.outstanding?(%QaFinding{decision: :fix})
  end

  test "a finding is undecided until it is ruled on, and a fixed one never is" do
    assert QaFinding.undecided?(%QaFinding{decision: nil})
    refute QaFinding.undecided?(%QaFinding{decision: nil, status: :fixed})
    refute QaFinding.undecided?(%QaFinding{decision: :skip})
  end

  test "a regression is what this change broke" do
    assert QaFinding.regression?(%QaFinding{caused_by_change: true})
    refute QaFinding.regression?(%QaFinding{caused_by_change: false})
  end

  test "a finding sits in exactly one state" do
    assert QaFinding.state(%QaFinding{status: :fixed, decision: :skip}) == :fixed
    assert QaFinding.state(%QaFinding{decision: :skip}) == :dismissed
    assert QaFinding.state(%QaFinding{decision: nil}) == :undecided
    assert QaFinding.state(%QaFinding{decision: :fix, status: :not_fixed}) == :not_fixed
    assert QaFinding.state(%QaFinding{decision: :fix}) == :to_fix
  end

  test "the enums and their labels are what the report is validated against" do
    assert QaFinding.severities() == [:blocker, :major, :minor, :nit]
    assert QaFinding.recommendations() == [:fix, :skip]
    assert QaFinding.statuses() == [:open, :fixed, :not_fixed]

    assert Enum.map(QaFinding.severities(), &QaFinding.severity_label/1) == ["Blocker", "Major", "Minor", "Nit"]
  end

  test "the human's ruling is the only thing that changeset writes" do
    changeset = QaFinding.decision_changeset(%QaFinding{title: "unchanged"}, :fix)

    assert changeset.changes == %{decision: :fix}
  end
end
