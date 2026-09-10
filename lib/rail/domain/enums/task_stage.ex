defmodule Rail.Domain.Enums.TaskStage do
  @moduledoc """
  Pipeline stages that a task walks from intake to merge.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :product,
      :design,
      :architect,
      :engineer,
      :review,
      :qa,
      :qa_lead,
      :demo,
      :ready_to_merge,
      :merged
    ],
    labels: %{
      product: "Product",
      design: "Design",
      architect: "Architect",
      engineer: "Engineer",
      review: "Review",
      qa: "QA",
      qa_lead: "QA Lead",
      demo: "Demo",
      ready_to_merge: "Ready to merge",
      merged: "Merged"
    }

  @doc "Returns the next stage in sequence, or nil if at the terminal stage."
  def next_stage(:product), do: :design
  def next_stage(:design), do: :architect
  def next_stage(:architect), do: :engineer
  def next_stage(:engineer), do: :review
  def next_stage(:review), do: :qa
  def next_stage(:qa), do: :qa_lead
  def next_stage(:qa_lead), do: :demo
  def next_stage(:demo), do: :ready_to_merge
  def next_stage(:ready_to_merge), do: :merged
  def next_stage(:merged), do: nil
  def next_stage(_other), do: nil

  @doc "Returns the previous stage in sequence, or nil if at the initial stage."
  def prev_stage(:product), do: nil
  def prev_stage(:design), do: :product
  def prev_stage(:architect), do: :design
  def prev_stage(:engineer), do: :architect
  def prev_stage(:review), do: :engineer
  def prev_stage(:qa), do: :review
  def prev_stage(:qa_lead), do: :qa
  def prev_stage(:demo), do: :qa_lead
  def prev_stage(:ready_to_merge), do: :demo
  def prev_stage(:merged), do: :ready_to_merge
  def prev_stage(_other), do: nil

  @doc "Alias for prev_stage/1."
  def previous_stage(stage), do: prev_stage(stage)

  @doc "Returns true if the stage can advance to a subsequent stage."
  def advanceable?(stage) when is_atom(stage) do
    stage in [
      :product,
      :design,
      :architect,
      :engineer,
      :review,
      :qa,
      :qa_lead,
      :demo,
      :ready_to_merge
    ]
  end

  def advanceable?(_other), do: false

  @doc "Returns true if the stage is an automated or human gate."
  def gate?(stage) when is_atom(stage), do: stage in [:review, :qa, :qa_lead]
  def gate?(_other), do: false

  @doc "Returns true if the stage is the terminal merged stage."
  def terminal?(:merged), do: true
  def terminal?(_other), do: false

  @doc "Returns the 0-indexed position of the stage in the pipeline."
  def index(:product), do: 0
  def index(:design), do: 1
  def index(:architect), do: 2
  def index(:engineer), do: 3
  def index(:review), do: 4
  def index(:qa), do: 5
  def index(:qa_lead), do: 6
  def index(:demo), do: 7
  def index(:ready_to_merge), do: 8
  def index(:merged), do: 9
  def index(_other), do: nil

  @doc "Returns true if stage_a comes before stage_b in the pipeline."
  def before?(stage_a, stage_b) when is_atom(stage_a) and is_atom(stage_b) do
    idx_a = index(stage_a)
    idx_b = index(stage_b)

    if idx_a && idx_b do
      idx_a < idx_b
    else
      false
    end
  end

  def before?(_stage_a, _stage_b), do: false

  @doc "Returns true if stage_a comes after stage_b in the pipeline."
  def after?(stage_a, stage_b) when is_atom(stage_a) and is_atom(stage_b) do
    idx_a = index(stage_a)
    idx_b = index(stage_b)

    if idx_a && idx_b do
      idx_a > idx_b
    else
      false
    end
  end

  def after?(_stage_a, _stage_b), do: false
end
