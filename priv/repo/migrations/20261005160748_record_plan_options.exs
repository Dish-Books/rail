defmodule Rail.Repo.Migrations.RecordPlanOptions do
  use Ecto.Migration

  # Approval now needs a plan that names the pick. Under the old flow the architect
  # only started once the design was approved, so a plan already saved on a task
  # moved into Plan was written for its pick, and the file `save_plan` keeps beside
  # the plan is written to say so. A task missing its scratch, plan or pick is left as it is.
  def up do
    %{rows: rows} =
      repo().query!("""
      SELECT tasks.scratch_path, issues.identifier
      FROM tasks JOIN issues ON issues.id = tasks.issue_id
      WHERE tasks.stage = 'plan' AND tasks.cleaned_up_at IS NULL
      """)

    for [scratch_path, identifier] <- rows do
      plans = Path.join(scratch_path, "plans")
      design = Path.join(scratch_path, "design")

      with true <- File.regular?(Path.join(plans, "#{identifier}.md")),
           {:ok, picked} <- File.read(Path.join(design, "picked")),
           key = String.trim(picked),
           {:ok, manifest} <- File.read(Path.join(design, "manifest.json")),
           {:ok, %{"options" => options}} when is_list(options) <- Jason.decode(manifest),
           %{"title" => title} when is_binary(title) <- Enum.find(options, &match?(%{"key" => ^key}, &1)) do
        path = Path.join(plans, "#{identifier}.design.json")
        temporary = path <> ".rewrite"
        File.write!(temporary, Jason.encode!(%{key: key, title: String.trim(title)}))
        File.rename!(temporary, path)
      end
    end
  end

  def down, do: :ok
end
