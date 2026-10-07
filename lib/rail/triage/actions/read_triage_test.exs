defmodule Rail.Triage.Actions.ReadTriageTest do
  use Rail.DataCase, async: true

  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread

  setup do
    thread = %Thread{id: "tth_read_#{System.unique_integer([:positive])}", project_id: "prj_read"}
    dir = Thread.scratch_path(thread)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{thread: thread, path: Path.join(dir, "result.json")}
  end

  test "keeps what fits the agreed shape and drops what does not", %{thread: thread, path: path} do
    File.write!(
      path,
      Jason.encode!(%{
        "title" => "  ",
        "messages" => [
          %{
            "ts" => "1.0",
            "needs_response" => false,
            "reason" => "Thanks",
            "items" => [%{"key" => "k", "change" => "bogus"}]
          },
          %{"no" => "ts"},
          "not a message"
        ],
        "items" => [
          %{
            "key" => "stuck",
            "kind" => "bug",
            "title" => " Stuck ",
            "verdict" => "confirmed",
            "evidence" => [%{"file" => "a.ex", "lines" => 4}, "not evidence"],
            "assumptions" => ["plain words", %{"text" => "an object", "corrected" => true}, 7],
            "issue" => "not a map"
          },
          %{"key" => "Bad Key", "kind" => "bug", "title" => "T", "verdict" => "confirmed"},
          %{"key" => "wrong-verdict", "kind" => "bug", "title" => "T", "verdict" => "built"},
          %{"key" => "no-kind", "title" => "T", "verdict" => "confirmed"},
          %{"title" => "no key"}
        ]
      })
    )

    assert %{
             title: nil,
             messages: [
               %{ts: "1.0", needs_response: false, reason: "Thanks", item_links: [%{item_key: "k", change: "raised"}]}
             ],
             items: [
               %{
                 key: "stuck",
                 title: "Stuck",
                 evidence: [%{file: "a.ex", lines: "4", holds: true}],
                 assumptions: [%{text: "plain words", corrected: false}, %{text: "an object", corrected: true}],
                 issue_title: nil
               }
             ]
           } = Triage.read_triage(thread)
  end

  test "keeps an issue estimate on the scale, and reads any other as none while keeping the draft", %{
    thread: thread,
    path: path
  } do
    items =
      for {key, estimate} <- [{"on-scale", 3}, {"missing", nil}, {"off-scale", 13}, {"text", "3"}, {"float", 3.0}] do
        issue = %{"title" => "Draft #{key}", "priority" => "high"}
        issue = if estimate, do: Map.put(issue, "estimate", estimate), else: issue
        %{"key" => key, "kind" => "bug", "title" => "T", "verdict" => "confirmed", "issue" => issue}
      end

    File.write!(path, Jason.encode!(%{"items" => items}))

    assert %{
             items: [
               %{key: "on-scale", issue_title: "Draft on-scale", issue_estimate: 3},
               %{key: "missing", issue_title: "Draft missing", issue_priority: "high", issue_estimate: nil},
               %{key: "off-scale", issue_title: "Draft off-scale", issue_priority: "high", issue_estimate: nil},
               %{key: "text", issue_title: "Draft text", issue_estimate: nil},
               %{key: "float", issue_title: "Draft float", issue_estimate: nil}
             ]
           } = Triage.read_triage(thread)
  end

  test "reads evidence lines given as text, a number or a range, and drops any other shape", %{
    thread: thread,
    path: path
  } do
    evidence = [
      %{"file" => "a.ex", "lines" => "10-12"},
      %{"file" => "a.ex", "lines" => 42},
      %{"file" => "a.ex", "lines" => [42, 45]},
      %{"file" => "a.ex", "lines" => %{"start" => 42}},
      %{"file" => "a.ex", "lines" => [1, 2, 3]}
    ]

    item = %{"key" => "k", "kind" => "bug", "title" => "T", "verdict" => "confirmed", "evidence" => evidence}
    File.write!(path, Jason.encode!(%{"items" => [item]}))

    assert %{items: [%{evidence: [%{lines: "10-12"}, %{lines: "42"}, %{lines: "42-45"}, %{lines: nil}, %{lines: nil}]}]} =
             Triage.read_triage(thread)
  end

  test "a missing or malformed file is nothing to read", %{thread: thread, path: path} do
    assert nil == Triage.read_triage(thread)

    File.write!(path, Jason.encode!(%{"items" => "not a list"}))
    assert nil == Triage.read_triage(thread)
  end
end
