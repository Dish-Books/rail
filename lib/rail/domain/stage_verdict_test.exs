defmodule Rail.Domain.StageVerdictTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.StageVerdict

  test "changeset/2 validates required verdict" do
    valid_changeset = StageVerdict.changeset(%StageVerdict{}, %{verdict: :passed, explanation: "All good"})
    assert valid_changeset.valid?

    invalid_changeset = StageVerdict.changeset(%StageVerdict{}, %{verdict: nil})
    refute invalid_changeset.valid?
    assert "can't be blank" in errors_on(invalid_changeset).verdict
  end

  test "reads the verdict line the stage brief asks for" do
    assert %StageVerdict{verdict: :passed} = StageVerdict.parse("findings...\n\nVERDICT: APPROVED")
    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse("findings...\n\nVERDICT: CHANGES REQUESTED")
    assert %StageVerdict{verdict: :passed} = StageVerdict.parse("table...\n\nVERDICT: PASS")
    assert %StageVerdict{verdict: :passed} = StageVerdict.parse("table...\n\nVERDICT: PASSED")
    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse("table...\n\nVERDICT: FAIL")
    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse("table...\n\nVERDICT: FAILED")
  end

  test "reads it through the markdown an agent wraps it in" do
    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse("## **Verdict:** `CHANGES REQUESTED`")
    assert %StageVerdict{verdict: :passed} = StageVerdict.parse("- **APPROVED**")
    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse("> VERDICT: FAILED")
  end

  test "takes the last verdict, since the words appear in the findings" do
    report = """
    [high] correctness lib/a.dart:12
    The check passed on the happy path only.
    I would have APPROVED this without the leak.

    VERDICT: CHANGES REQUESTED
    """

    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse(report)
  end

  test "ignores the pass/fail cells in a QA table" do
    report = """
    | check | result | severity | evidence |
    | --- | --- | --- | --- |
    | task persists a restart | pass | - | tasks/task-1.json |
    | hot restart mid-run | fail | blocker | console line 40 |

    VERDICT: FAIL
    """

    assert %StageVerdict{verdict: :changes_requested} = StageVerdict.parse(report)
  end

  test "a sentence about the review is not a verdict line" do
    assert %StageVerdict{verdict: :unclear} = StageVerdict.parse("APPROVED with three nits I have not listed")
    assert %StageVerdict{verdict: :unclear} = StageVerdict.parse("This would have passed if the timer were disposed")
  end

  test "a report that states none is unclear rather than a guess" do
    assert %StageVerdict{verdict: :unclear} = StageVerdict.parse("")
    assert %StageVerdict{verdict: :unclear} = StageVerdict.parse(nil)
    assert %StageVerdict{verdict: :unclear} = StageVerdict.parse("I could not read the diff; the worktree was gone.")
  end

  test "an explained verdict still reads and captures explanation" do
    res1 = StageVerdict.parse("VERDICT: APPROVED - the nits can follow up")
    assert res1.verdict == :passed
    assert res1.explanation == "the nits can follow up"

    res2 = StageVerdict.parse("APPROVED.")
    assert res2.verdict == :passed
    assert is_nil(res2.explanation)

    res3 = StageVerdict.parse("VERDICT: CHANGES REQUESTED : please fix test failures")
    assert res3.verdict == :changes_requested
    assert res3.explanation == "please fix test failures"
  end

  test "helpers passed?/1, changes_requested?/1, and unclear?/1" do
    passed = %StageVerdict{verdict: :passed}
    changes_req = %StageVerdict{verdict: :changes_requested}
    unclear = %StageVerdict{verdict: :unclear}

    assert StageVerdict.passed?(passed)
    assert StageVerdict.passed?(:passed)
    assert StageVerdict.passed?("VERDICT: APPROVED")
    refute StageVerdict.passed?(changes_req)
    refute StageVerdict.passed?(:changes_requested)
    refute StageVerdict.passed?(:other)

    assert StageVerdict.changes_requested?(changes_req)
    assert StageVerdict.changes_requested?(:changes_requested)
    assert StageVerdict.changes_requested?("VERDICT: FAIL")
    refute StageVerdict.changes_requested?(passed)
    refute StageVerdict.changes_requested?(:passed)
    refute StageVerdict.changes_requested?(:other)

    assert StageVerdict.unclear?(unclear)
    assert StageVerdict.unclear?(:unclear)
    assert StageVerdict.unclear?("nothing clear")
    refute StageVerdict.unclear?(passed)
    refute StageVerdict.unclear?(:passed)
    refute StageVerdict.unclear?(:other)
  end

  test "format/1 and format/2 serialize to expected strings" do
    assert StageVerdict.format(:passed) == "VERDICT: APPROVED"
    assert StageVerdict.format(:passed, "looks great") == "VERDICT: APPROVED - looks great"
    assert StageVerdict.format(:changes_requested, "needs work") == "VERDICT: CHANGES REQUESTED - needs work"
    assert StageVerdict.format(:unclear) == "VERDICT: UNCLEAR"

    verdict_struct = %StageVerdict{verdict: :passed, explanation: "well done"}
    assert StageVerdict.format(verdict_struct) == "VERDICT: APPROVED - well done"
  end
end
