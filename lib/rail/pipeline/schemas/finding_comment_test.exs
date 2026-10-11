defmodule Rail.Pipeline.Schemas.FindingCommentTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace

  @at ~U[2026-10-09 12:00:00Z]

  setup do
    %{
      finding: %Finding{
        key: "send-twice",
        kind: :screen,
        title: "Send stays enabled",
        problem: "A second click sends twice.",
        screen: "Engineer tab, Diff toolbar",
        steps: ["Comment on a line", "Click Send twice"],
        fix: "Disable Send until the server answers.",
        why: "Two runs for one round.",
        rule: "A round is sent once.",
        recommendation: :fix,
        places: [
          %FindingPlace{file: "lib/a.ex", line: 3, end_line: 9, label: "handle_event/3"},
          %FindingPlace{screen: "Review tray", left_reason: "Sends once already."}
        ],
        notes: [
          %FindingNote{round: 1, kind: :raised, at: @at, commit: "abcdef1234", text: "Seen twice."},
          %FindingNote{round: 1, kind: :ruling, at: @at, decision: :skip},
          %FindingNote{round: 1, kind: :ruling, at: @at, decision: :fix},
          %FindingNote{round: 2, kind: :fix, at: @at, commit: "1234567abc", test: "sends once"},
          %FindingNote{round: 2, kind: :fix, at: @at, test: "sends once"},
          %FindingNote{round: 3, kind: :carried, at: @at},
          %FindingNote{round: 3, kind: :pass, at: @at, status: :not_fixed, commit: "fedcba9876", text: "Still twice."},
          %FindingNote{round: 4, kind: :pass, at: @at, status: :fixed},
          %FindingNote{round: 4, kind: :pass, at: @at, status: :open}
        ]
      }
    }
  end

  test "a comment needs a finding, a piece and text, and its text is trimmed" do
    assert %{valid?: true, changes: %{finding_id: "fnd_1", piece: :place, index: 1, body: "Fold it."}} =
             FindingComment.changeset(%FindingComment{}, %{
               "finding_id" => "fnd_1",
               "piece" => "place",
               "index" => 1,
               "body" => "  Fold it.\n"
             })

    refute FindingComment.changeset(%FindingComment{}, %{"finding_id" => "fnd_1", "piece" => "fix", "body" => " "}).valid?
    refute FindingComment.changeset(%FindingComment{}, %{"piece" => "fix", "body" => "Fold it."}).valid?
    refute FindingComment.changeset(%FindingComment{}, %{"finding_id" => "fnd_1", "body" => "Fold it."}).valid?

    refute FindingComment.changeset(%FindingComment{}, %{"finding_id" => "fnd_1", "piece" => "verdict", "body" => "x"}).valid?

    refute FindingComment.changeset(%FindingComment{}, %{
             "finding_id" => "fnd_1",
             "piece" => "place",
             "index" => -1,
             "body" => "x"
           }).valid?
  end

  test "each whole piece reads by its label and its text as the finding shows it", %{finding: finding} do
    assert %{label: "Title", quote: "Send stays enabled"} = FindingComment.calculate_piece(finding, :title, nil)

    assert %{label: "Problem", quote: "A second click sends twice."} =
             FindingComment.calculate_piece(finding, :problem, nil)

    assert %{label: "Where", quote: "Engineer tab, Diff toolbar\n1. Comment on a line\n2. Click Send twice"} =
             FindingComment.calculate_piece(finding, :where, nil)

    assert %{label: "Fix", quote: "Disable Send until the server answers."} =
             FindingComment.calculate_piece(finding, :fix, nil)

    assert %{label: "Why fix", quote: "Two runs for one round."} = FindingComment.calculate_piece(finding, :why, nil)

    assert %{label: "Why skip"} =
             FindingComment.calculate_piece(%{finding | recommendation: :skip}, :why, nil)

    assert %{label: "Rule", quote: "A round is sent once."} = FindingComment.calculate_piece(finding, :rule, nil)

    assert %{label: "Where", quote: "lib/a.ex:3"} =
             FindingComment.calculate_piece(%Finding{kind: :code, file: "lib/a.ex", line: 3, steps: []}, :where, nil)
  end

  test "a place reads by its number and label, and a note by its round, each quoting what it says", %{
    finding: finding
  } do
    assert %{label: "Place 1, handle_event/3", quote: "lib/a.ex:3-9"} =
             FindingComment.calculate_piece(finding, :place, 0)

    assert %{label: "Place 2", quote: "Review tray\nLeft as it is: Sends once already."} =
             FindingComment.calculate_piece(finding, :place, 1)

    assert [
             %{label: "Round 1, raised", quote: "Raised on abcdef1: Seen twice."},
             %{label: "Round 1, ruled Don't fix", quote: "Ruled Don't fix"},
             %{label: "Round 1, ruled Fix", quote: "Ruled Fix"},
             %{label: "Fix round 2, fix report", quote: "Fixed in 1234567; test that failed first: sends once"},
             %{label: "Fix round 2, fix report", quote: "Fixed; test that failed first: sends once"},
             %{label: "Round 3, carried", quote: "Carried into round 3 with its Fix ruling"},
             %{label: "Round 3 pass, still failing", quote: "Still failing on fedcba9: Still twice."},
             %{label: "Round 4 pass, checked fixed", quote: "Checked fixed"},
             %{label: "Round 4 pass, still open", quote: "Still open"}
           ] = Enum.map(0..8, &FindingComment.calculate_piece(finding, :note, &1))
  end

  test "a piece the finding does not have is nil", %{finding: finding} do
    assert FindingComment.calculate_piece(finding, :place, 2) == nil
    assert FindingComment.calculate_piece(finding, :note, 9) == nil
    assert FindingComment.calculate_piece(finding, :place, nil) == nil
    assert FindingComment.calculate_piece(finding, :title, 0) == nil
    assert FindingComment.calculate_piece(finding, nil, nil) == nil
    assert FindingComment.calculate_piece(%{finding | problem: nil}, :problem, nil) == nil
    assert FindingComment.calculate_piece(%{finding | rule: ""}, :rule, nil) == nil
  end

  test "comments go in the order written, the id breaking a tie" do
    later = %FindingComment{id: "fcm_a", inserted_at: ~U[2026-10-09 12:00:01.000001Z]}
    tie_b = %FindingComment{id: "fcm_c", inserted_at: ~U[2026-10-09 12:00:00.000001Z]}
    tie_a = %FindingComment{id: "fcm_b", inserted_at: ~U[2026-10-09 12:00:00.000001Z]}

    assert [%{id: "fcm_b"}, %{id: "fcm_c"}, %{id: "fcm_a"}] = FindingComment.calculate_order([later, tie_b, tie_a])
  end

  test "the block names the finding, its ruling and the piece, quoting it, then the comment", %{finding: finding} do
    comment = %FindingComment{
      finding: %{finding | decision: :skip},
      label: "Where",
      quote: "Engineer tab, Diff toolbar\n1. Comment on a line",
      body: "It is the Review tray too."
    }

    block = FindingComment.calculate_block(comment)

    Enum.reduce(
      [
        "send-twice",
        "Don't fix",
        "Send stays enabled",
        "Where",
        "Engineer tab, Diff toolbar",
        "1. Comment on a line",
        "It is the Review tray too."
      ],
      0,
      fn part, from ->
        assert {at, length} = :binary.match(block, part, scope: {from, byte_size(block) - from})
        at + length
      end
    )

    fixed = FindingComment.calculate_block(%{comment | finding: %{finding | decision: :fix}})
    assert fixed =~ "Fix"
    refute fixed =~ "Don't fix"
    assert FindingComment.calculate_block(%{comment | finding: %{finding | decision: nil}}) =~ "Not ruled"
  end
end
