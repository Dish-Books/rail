defmodule Rail.Learnings.Actions.RecordCorrectionsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Learnings.Workers.EmbedLearning
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.PlanCommentCapture
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
        suggestion: "Match nil before reading the map.",
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
             rule: "Match nil before reading the map.",
             why: "Raised in review on lib/a.ex and sent to be fixed: Nil is not handled\n\nIt assumes a map."
           } = review_rule

    assert %Learning{
             kind: :convention,
             roles: [:engineer, :qa],
             rule: "The total is unrounded",
             why: "Raised by QA and sent to be fixed.\n\nEvery bill shows it."
           } = qa_rule

    assert %Learning{
             kind: :decision,
             roles: [],
             rule: ~s(When asked "Indigo or blue?": Blue, to match the review tab.),
             why: nil
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

  test "a design comment becomes a Design rule for Designer whose reason names its element and quotes its start", %{
    task: %{id: task_id} = task,
    user_id: user_id
  } do
    html = ~s(<h2 id="needs">Needs you <span>3</span></h2>) <> String.duplicate("x", 2_500)

    comment = %PlanComment{
      id: "pcm_rc_1",
      target: :design,
      user_id: user_id,
      option_key: "waiting-lanes",
      selector: "#needs",
      element_text: "Needs you 3",
      element_tag: "h2",
      body: "Say how long the oldest one has waited.",
      capture: %PlanCommentCapture{html: html, width: 180, height: 22}
    }

    why =
      ~s(From a design comment on waiting-lanes, `#needs` "Needs you 3":\n\n```html\n) <>
        String.slice(html, 0, 2_000) <> "\n<!-- Rail cut the element's HTML here, at 2,000 characters. -->\n```"

    assert {:ok,
            [
              %Learning{
                id: rule_id,
                status: :provisional,
                kind: :design,
                roles: [:design],
                rule: "Say how long the oldest one has waited.",
                why: ^why
              }
            ]} = Learnings.record_corrections(task, [comment])

    assert [
             %Observation{
               source_kind: :design_comment,
               source_id: "pcm_rc_1",
               actor_id: ^user_id,
               task_id: ^task_id,
               text: "Say how long the oldest one has waited.",
               capture: %{"html" => ^html, "width" => 180, "height" => 22},
               learning_id: ^rule_id
             }
           ] = Repo.all(from o in Observation, where: o.task_id == ^task_id)

    assert {:ok, []} = Learnings.record_corrections(task, [comment])
  end

  test "a design comment on an element with no text names its tag, and a short element is quoted whole", %{task: task} do
    comment = %PlanComment{
      id: "pcm_rc_2",
      target: :design,
      option_key: "waiting-lanes",
      selector: "#lane > span:nth-child(2)",
      element_text: "",
      element_tag: "span",
      body: "Drop the dot.",
      capture: %PlanCommentCapture{html: "<span></span>", width: 10, height: 10}
    }

    assert {:ok,
            [
              %Learning{
                why:
                  "From a design comment on waiting-lanes, `#lane > span:nth-child(2)` <span>:\n\n```html\n<span></span>\n```"
              }
            ]} =
             Learnings.record_corrections(task, [comment])
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

    assert {:ok, [%Learning{rule: ~s(When asked "Blue or indigo?": Indigo.)}]} =
             Learnings.record_corrections(later, [taken, rewritten])

    assert %Observation{learning_id: ^past_id} = Repo.get_by!(Observation, source_id: "qst_rc_2")
  end

  test "Use this answer on a rule a person reworded joins that rule", %{
    project: project,
    task: task,
    records: records
  } do
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

  test "a Fix on a finding raised from a rule counts against that rule rather than copying it", %{
    project: project,
    task: task,
    user_id: user_id
  } do
    %{id: rule_id} = learning(project, %{rule: "Amber is for warnings only", kind: :design})

    finding = %ReviewFinding{
      id: "rvf_rc_rule",
      decided_by_id: user_id,
      title: "Comment body uses amber for ordinary text",
      rule_id: rule_id
    }

    assert {:ok, []} = Learnings.record_corrections(task, [finding])

    assert %Observation{source_kind: :review_finding, learning_id: ^rule_id} =
             Repo.get_by!(Observation, source_id: "rvf_rc_rule")

    assert [%Learning{id: ^rule_id}] = Repo.all(from l in Learning, where: l.project_id == ^project.id)
  end
end
