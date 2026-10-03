defmodule Rail.Learnings.Actions.RecordCorrectionsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Learnings.Workers.EmbedLearning
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Users

  setup %{project: project} do
    {:ok, user} = Users.register_oauth_user(%{github_id: "rc-1", login: "dana", name: "Dana", email: "dana@rc.example"})
    task = learnings_task(project, "COR-1")

    records = [
      %DiffComment{
        id: "dcm_rc_1",
        user_id: user.id,
        path: "lib/rail/a.ex",
        line_text: "Repo.insert!(row)",
        context_text: "  + rows = build()\n> + Repo.insert!(row)",
        body: "Use the factory here"
      },
      %ReviewFinding{
        id: "rvf_rc_1",
        decided_by_id: user.id,
        title: "Nil is not handled",
        detail: "It assumes a map.",
        file: "lib/a.ex"
      },
      %QaFinding{
        id: "qaf_rc_1",
        decided_by_id: user.id,
        title: "The total is unrounded",
        detail: "Every bill shows it.",
        observed: "$1234.5"
      },
      %Question{
        id: "qst_rc_1",
        answered_by_id: user.id,
        prompt: "Indigo or blue?",
        answer: "Blue, to match the review tab.",
        status: :answered
      }
    ]

    %{task: task, records: records, user_id: user.id}
  end

  test "each correction becomes one observation and one provisional rule of the right kind and roles", %{
    task: %{project_id: project_id} = task,
    records: records,
    user_id: user_id
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "learnings")

    assert {:ok, [%Learning{id: comment_rule_id} = comment_rule, review_rule, qa_rule, answer_rule]} =
             Learnings.record_corrections(task, records)

    assert %Learning{
             status: :provisional,
             kind: :convention,
             roles: [:engineer, :review],
             rule: "Use the factory here",
             why: why
           } =
             comment_rule

    assert why =~ "lib/rail/a.ex"
    assert why =~ "> + Repo.insert!(row)"

    assert %Learning{
             kind: :convention,
             roles: [:engineer, :review],
             rule: "Nil is not handled",
             why: "Raised in review on lib/a.ex" <> _rest
           } = review_rule

    assert %Learning{kind: :convention, roles: [:engineer, :qa], rule: "The total is unrounded"} = qa_rule

    assert %Learning{
             kind: :decision,
             roles: [],
             rule: "Blue, to match the review tab.",
             why: "The answer when asked: Indigo or blue?"
           } = answer_rule

    assert [
             %Observation{
               source_kind: :diff_comment,
               source_id: "dcm_rc_1",
               actor_id: ^user_id,
               excerpt: "  + rows = build()\n> + Repo.insert!(row)",
               learning_id: ^comment_rule_id
             },
             %Observation{source_kind: :review_finding},
             %Observation{source_kind: :qa_finding, excerpt: "$1234.5"},
             %Observation{source_kind: :answer, excerpt: "Blue, to match the review tab."}
           ] =
             from(o in Observation, where: o.task_id == ^task.id, order_by: [asc: o.source_kind])
             |> Repo.all()
             |> Enum.sort_by(
               &Enum.find_index([:diff_comment, :review_finding, :qa_finding, :answer], fn kind ->
                 kind == &1.source_kind
               end)
             )

    for rule <- [comment_rule, review_rule, qa_rule, answer_rule],
        do: assert_enqueued(worker: EmbedLearning, args: %{learning_id: rule.id})

    assert_received {:learnings_changed, ^project_id}
  end

  test "recording the same batch twice adds nothing", %{task: task, records: records} do
    {:ok, _first} = Learnings.record_corrections(task, records)

    assert {:ok, []} = Learnings.record_corrections(task, records)
    assert 4 == Repo.aggregate(from(o in Observation, where: o.task_id == ^task.id), :count)
  end

  test "a comment saved before blocks were kept is quoted by its line", %{task: task} do
    comment = %DiffComment{id: "dcm_rc_old", path: "a.ex", line_text: "old line", context_text: "", body: "Rename it"}

    assert {:ok, [%Learning{why: "From a diff comment on a.ex:\n\nold line"}]} =
             Learnings.record_corrections(task, [comment])
  end

  test "an answer taken from the past answer Rail suggested joins that rule instead of making another", %{
    project: project,
    task: task,
    records: records
  } do
    {:ok, [_comment, _review, _qa, %Learning{id: past_id} = past]} = Learnings.record_corrections(task, records)
    later = learnings_task(project, "COR-2")

    taken = %Question{
      id: "qst_rc_2",
      prompt: "Blue or indigo?",
      answer: "Blue, to match the review tab.",
      status: :answered,
      suggested_learning_id: past.id
    }

    rewritten = %Question{
      id: "qst_rc_3",
      prompt: "Blue or indigo?",
      answer: "Indigo.",
      status: :answered,
      suggested_learning_id: past.id
    }

    assert {:ok, [%Learning{rule: "Indigo."}]} = Learnings.record_corrections(later, [taken, rewritten])
    assert %Observation{learning_id: ^past_id} = Repo.get_by!(Observation, source_id: "qst_rc_2")
  end

  test "an answer taken from a rule edited since joins that rule", %{project: project, task: task, records: records} do
    {:ok, [_comment, _review, _qa, %Learning{id: past_id} = past]} = Learnings.record_corrections(task, records)
    {:ok, _edited} = Learnings.update_learning(system_scope(), past, %{rule: "Blue, as the review tab is."})
    later = learnings_task(project, "COR-3")

    taken = %Question{
      id: "qst_rc_4",
      prompt: "Blue or indigo?",
      answer: "Blue, as the review tab is.",
      status: :answered,
      suggested_learning_id: past_id
    }

    assert {:ok, []} = Learnings.record_corrections(later, [taken])
    assert %Observation{learning_id: ^past_id} = Repo.get_by!(Observation, source_id: "qst_rc_4")
  end
end
