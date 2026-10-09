defmodule Rail.Pipeline.Schemas.FindingTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace

  setup do
    %{
      attrs: %{
        "key" => "unhandled-nil",
        "kind" => "code",
        "raised_by" => "code_reviewer",
        "title" => "Nil is not handled",
        "problem" => "A task with no worktree crashes the page.",
        "file" => "lib/a.ex",
        "line" => 3,
        "end_line" => 9,
        "fix" => "Guard the nil in the action.",
        "why" => "It crashes for everyone who opens the task.",
        "rule" => "Every caller handles a missing worktree.",
        "severity" => "major",
        "recommendation" => "fix",
        "places" => [%{"file" => "lib/a.ex", "line" => 3, "label" => "handle/1"}],
        "evidence" => [%{"name" => "The clause", "kind" => "code", "file" => "lib/a.ex", "line" => 3}]
      }
    }
  end

  test "a finding with everything it says is valid, and Where reads as its range", %{attrs: attrs} do
    changeset = Finding.raise_changeset(%Finding{}, attrs)

    assert changeset.valid?

    assert %Finding{places: [%FindingPlace{label: "handle/1"}], evidence: [%FindingEvidence{kind: :code}]} =
             finding = Ecto.Changeset.apply_changes(changeset)

    assert Finding.where(finding) == "lib/a.ex:3-9"
  end

  test "a finding with no evidence and no place is refused naming both", %{attrs: attrs} do
    changeset = Finding.raise_changeset(%Finding{}, %{attrs | "evidence" => [], "places" => []})

    assert %{
             evidence: ["needs at least one highlighted code range, screenshot, file or note"],
             places: ["needs every place the rule applies, at least one"]
           } = errors_on(changeset)
  end

  test "every field is held to its limit", %{attrs: attrs} do
    long = %{
      "title" => String.duplicate("t", 91),
      "problem" => String.duplicate("p", 301),
      "fix" => String.duplicate("f", 301),
      "why" => String.duplicate("w", 201),
      "rule" => String.duplicate("r", 161)
    }

    assert %{
             title: ["should be at most 90 character(s)"],
             problem: ["should be at most 300 character(s)"],
             fix: ["should be at most 300 character(s)"],
             why: ["should be at most 200 character(s)"],
             rule: ["should be at most 160 character(s)"]
           } = errors_on(Finding.raise_changeset(%Finding{}, Map.merge(attrs, long)))
  end

  test "a finding holding tool-call markup is refused", %{attrs: attrs} do
    changeset = Finding.raise_changeset(%Finding{}, %{attrs | "fix" => ~s(Guard it <invoke name="save_finding">)})

    assert %{fix: ["holds tool-call markup; write it as plain text"]} = errors_on(changeset)
  end

  test "a place or a piece of evidence holding tool-call markup is refused", %{attrs: attrs} do
    changeset =
      Finding.raise_changeset(%Finding{}, %{
        attrs
        | "places" => [%{"file" => "lib/a.ex", "label" => "</parameter>"}],
          "evidence" => [%{"name" => "log", "kind" => "note", "text" => "<function_calls>"}]
      })

    assert %{places: [%{label: ["holds tool-call markup"]}], evidence: [%{text: ["holds tool-call markup"]}]} =
             errors_on(changeset)
  end

  test "a code finding needs its line, and a screen finding its screen and steps", %{attrs: attrs} do
    assert %{file: ["a code finding's Where is the `file` and `line` it is in"]} =
             errors_on(Finding.raise_changeset(%Finding{}, Map.delete(attrs, "line")))

    screen = Map.merge(attrs, %{"kind" => "screen", "file" => nil, "screen" => "Engineer tab", "steps" => []})

    assert %{screen: ["a screen finding's Where is the `screen` and the `steps` to it"]} =
             errors_on(Finding.raise_changeset(%Finding{}, screen))

    assert Finding.raise_changeset(%Finding{}, %{screen | "steps" => ["Open the task"]}).valid?
  end

  test "evidence and places stay inside their roots", %{attrs: attrs} do
    changeset =
      Finding.raise_changeset(%Finding{}, %{
        attrs
        | "places" => [%{"file" => "../outside.ex"}, %{"label" => "nowhere"}],
          "evidence" => [
            %{"name" => "secrets", "kind" => "log", "path" => "../../etc/passwd"},
            %{"name" => "range", "kind" => "code", "file" => "/etc/passwd", "line" => 1},
            %{"name" => "nothing", "kind" => "log"},
            %{"name" => "no line", "kind" => "code", "file" => "lib/a.ex"}
          ]
      })

    assert %{
             places: [
               %{file: ["is a path relative to the worktree, never climbing out with `..`"]},
               %{file: ["a place is a `file` with its lines or a `screen` with its steps"]}
             ],
             evidence: [
               %{path: [_format_or_climb | _rest]},
               %{file: ["is a path relative to the worktree, never climbing out with `..`"]},
               %{path: ["evidence needs a file or some text"]},
               %{file: ["code evidence needs the `file` and `line` it highlights"]}
             ]
           } = errors_on(changeset)
  end

  test "a note is appended with its status, and a note over 300 characters or holding markup is refused" do
    finding = %Finding{notes: [%FindingNote{round: 1, kind: :raised, at: DateTime.utc_now()}]}
    note = %{round: 2, kind: :pass, at: DateTime.utc_now(), status: :not_fixed, text: "Still fails on Send."}

    assert %Finding{status: :not_fixed, notes: [%FindingNote{kind: :raised}, %FindingNote{kind: :pass, round: 2}]} =
             finding |> Finding.note_changeset(%{status: :not_fixed, note: note}) |> Ecto.Changeset.apply_changes()

    assert %{note: ["should be at most 300 character(s)"]} =
             errors_on(Finding.note_changeset(finding, %{note: %{note | text: String.duplicate("n", 301)}}))

    assert %{note: ["holds tool-call markup; write it as plain text"]} =
             errors_on(Finding.note_changeset(finding, %{note: %{note | text: "<tool_use>"}}))
  end

  test "a Fix finding a pass found still failing stays outstanding and asks for no new ruling" do
    still_failing = %Finding{decision: :fix, status: :not_fixed}

    assert Finding.outstanding?(still_failing)
    refute Finding.undecided?(still_failing)
    assert Finding.state(still_failing) == :not_fixed
  end

  test "each ruling and status reads as one state" do
    assert Finding.state(%Finding{status: :fixed, decision: :fix}) == :fixed
    assert Finding.state(%Finding{decision: :skip}) == :dismissed
    assert Finding.state(%Finding{suppressed_by_id: "lrn_1"}) == :suppressed
    assert Finding.state(%Finding{}) == :undecided
    assert Finding.state(%Finding{decision: :fix}) == :to_fix

    assert Finding.undecided?(%Finding{})
    refute Finding.undecided?(%Finding{suppressed_by_id: "lrn_1"})
    refute Finding.undecided?(%Finding{status: :fixed})
    refute Finding.outstanding?(%Finding{status: :fixed, decision: :fix})
    refute Finding.outstanding?(%Finding{decision: :skip})
    assert Finding.suppressed?(%Finding{suppressed_by_id: "lrn_1"})
    refute Finding.suppressed?(%Finding{suppressed_by_id: "lrn_1", decision: :fix})
    refute Finding.suppressed?(%Finding{suppressed_by_id: "lrn_1", status: :fixed})
  end

  test "a finding is where its code is, or the screen it was seen on" do
    assert Finding.where(%Finding{file: "lib/a.ex", line: 3}) == "lib/a.ex:3"
    assert Finding.where(%Finding{file: "lib/a.ex"}) == "lib/a.ex"
    assert Finding.where(%Finding{screen: "Engineer tab"}) == "Engineer tab"
    assert FindingPlace.describe(%FindingPlace{screen: "Engineer tab"}) == "Engineer tab"
  end

  test "a ruling is the human's, with who made it" do
    assert %{changes: %{decision: :skip, decided_by_id: "usr_1"}} =
             Finding.decision_changeset(%Finding{}, :skip, "usr_1")
  end

  test "evidence paths and pictures are read by name" do
    assert FindingEvidence.confined?("evidence/a~b.jpg")
    refute FindingEvidence.confined?("../a.jpg")
    assert FindingEvidence.picture?("evidence/a.PNG")
    refute FindingEvidence.picture?("evidence/a.log")
  end

  test "the lists a reader groups and labels by" do
    assert Finding.severities() == [:blocker, :major, :minor, :nit]
    assert Finding.kinds() == [:code, :screen]
    assert Finding.raised_by() == [:code_reviewer, :explorer, :review_lead]
    assert Enum.map(Finding.severities(), &Finding.severity_label/1) == ["Blocker", "Major", "Minor", "Nit"]
    refute Finding.markup?(nil)
  end
end
