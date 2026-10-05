defmodule RailTest.Helpers do
  @moduledoc false

  import Ecto.Query

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.ReviewFinding
  alias Rail.Repo

  defdelegate create_temp_git_repo(opts \\ []), to: RailTest.GitHelpers
  defdelegate git!(dir, args), to: RailTest.GitHelpers

  defdelegate stub_slack(opts \\ []), to: RailTest.TriageHelpers
  defdelegate connect_slack_channel(project, opts \\ []), to: RailTest.TriageHelpers
  defdelegate slack_message_event(channel, fields), to: RailTest.TriageHelpers
  defdelegate triage_project(), to: RailTest.TriageHelpers
  defdelegate triage_with(thread, result), to: RailTest.TriageHelpers
  defdelegate triage_bug(overrides \\ %{}), to: RailTest.TriageHelpers
  defdelegate slack_user(team_id, name \\ "Michael"), to: RailTest.TriageHelpers

  @doc """
  Runs `fun` until its assertions hold, or `timeout` passes.

  Anything a timer drives - a tail poll, a batch tick, a process noticing it has
  exited - lands when the scheduler gets to it, not when a fixed sleep says it
  should. Sleeping for the interval and asserting once passes on an idle machine
  and fails on a loaded one; this waits for the state the test is actually about.
  """
  def eventually(fun, timeout \\ 2_000) when is_function(fun, 0) do
    attempt(fun, System.monotonic_time(:millisecond) + timeout)
  end

  @doc """
  An implementation plan in the section format the Architect prompt asks for, with
  both diagrams and a Program design.
  """
  def sheet_plan, do: File.read!("test/support/fixtures/sheet_plan.md")

  @doc """
  Saves each of `findings` on `task` as a reviewer would, one call each, and
  returns every finding the task now has, oldest first.
  """
  def save_review_findings(task, findings) do
    for finding <- findings, do: {:ok, %ReviewFinding{}} = Pipeline.save_review_finding(task, finding)

    {:ok, Repo.all(from f in ReviewFinding, where: f.task_id == ^task.id, order_by: [asc: f.inserted_at, asc: f.id])}
  end

  @doc """
  Saves each of `findings` on `task` as QA would, and returns every finding the
  task now has, oldest first. A finding arranged without evidence is given a note,
  since QA cannot save one without.
  """
  def save_qa_findings(task, findings) do
    for finding <- findings do
      evidenced =
        if Map.has_key?(finding, "key"),
          do: Map.put_new(finding, "evidence", [%{"name" => "what QA saw", "kind" => "note", "text" => "Seen."}]),
          else: Map.put_new(finding, :evidence, [%{name: "what QA saw", kind: :note, text: "Seen."}])

      {:ok, %QaFinding{}} = Pipeline.save_qa_finding(task, evidenced)
    end

    {:ok, Repo.all(from f in QaFinding, where: f.task_id == ^task.id, order_by: [asc: f.inserted_at, asc: f.id])}
  end

  @doc """
  Puts a session token for `user` on `conn` so requests are authenticated.
  """
  def log_in_user(conn, user) do
    token = Rail.Users.generate_user_session_token(user)

    conn
    |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end

  defp attempt(fun, deadline) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        attempt(fun, deadline)
      else
        reraise error, __STACKTRACE__
      end
  end
end
