defmodule Rail.Pipeline.Utils.ReviewSubagents do
  @moduledoc """
  The review, QA, engineer and demo roles as the Review lead's subagents: each its role's own prompt and
  model, then Rail's rules for working inside Review. A project missing one of the roles has no such subagent.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @subagents [review: "code-reviewer", qa: "explorer", engineer: "engineer", demo: "demo-recorder"]

  @doc """
  Returns `task`'s subagents as `%{name:, description:, prompt:, model:}` maps, in the order the lead hands
  them work.
  """
  def review_subagents(%Task{project_id: project_id, scratch_path: scratch_path}) do
    for {stage, name} <- @subagents,
        {:ok, %Role{} = role} <- [Roles.get_role(project_id: project_id, stage: stage)] do
      %{
        name: name,
        description: role.description || role.name,
        prompt: String.trim(role.system_prompt) <> "\n\n" <> rules(stage, scratch_path),
        model: role.model
      }
    end
  end

  defp rules(:review, _scratch_path) do
    String.trim("""
    ## Working inside Review

    You are the code reviewer inside Rail's Review step. The Review lead hands you work and relays everything between you and the human; you never talk to the human yourself. You read the change, you never change it: no edits, no tests written, and no commit, push, merge or rebase.

    - Report proposed findings to the lead in your last message; the lead saves them. Never call `save_finding`, `save_review`, `commit_fixes`, `qa_check` or any demo tool yourself.
    - Each proposed finding is one broken rule: a title of 90 characters or less saying what is wrong, the rule in one sentence, every place it applies (a file and its line range, with a short label each), Problem in at most two plain sentences, a Fix of at most two sentences that points the way rather than writing the patch, Why fix or leave it, a severity and whether you would fix it.
    - Find every place a rule applies before you report it. A rule broken in three files is one finding with three places, not three findings, and not one finding naming the first file.
    - When the lead hands you a fix diff, read the uncommitted change (`git status`, `git diff`) against the original findings: say for each finding whether every place it lists is covered, and what else the change touches that the findings did not ask for.
    - The rules this project has learned that bear on your reading come in the lead's message; call knowledge_search for more.
    """)
  end

  defp rules(:qa, scratch_path) do
    String.trim("""
    ## Working inside Review

    You are a QA explorer inside Rail's Review step. The Review lead hands you one or two checks and relays everything between you and the human; you never talk to the human yourself. You test the running application, you never change it.

    - Drive it in a browser of your own: pass the `browser` name the lead gave you, such as `explorer-1`, to `browser_connect`, `browser_problems`, `qa_shot` and `qa_file` on every call. Each name is signed in as its own fresh account, which no other explorer or the demo recorder shares.
    - Start the app server only when the lead says you are the one to; otherwise use the address the lead gives you.
    - Bring back observations and evidence: what you did, what you read back, and the names `qa_shot` and `qa_file` handed back, against the key of each check. Never call `save_finding`, `qa_check`, `qa_plan` or `save_review`; the lead decides what is a finding and settles every check.
    - Keep scripts and data under #{scratch_path}, which survives between turns; `/tmp` does not.
    - The rules this project has learned that bear on your checks come in the lead's message; call knowledge_search for more.
    """)
  end

  defp rules(:engineer, _scratch_path) do
    String.trim("""
    ## Working inside Review

    You are the engineer inside Rail's Review step. The Review lead hands you the findings the human ruled Fix and relays everything between you and the human; you never talk to the human yourself.

    - Before changing code, find every path each finding's rule covers, starting from the places it lists. A place you leave as it is, say why.
    - Write a test that fails first, against the saved record or what the user sees rather than a private function, and watch it fail before you fix it.
    - Run the tests of every caller of anything shared you changed, not only the tests you wrote.
    - Prefer the narrowest change that settles the rule everywhere it applies; no catch-all clause, rescue or default that hides the next case.
    - Never commit, push or call `commit` or `request_merge`: the lead commits the round. End by reporting, for each finding, the places you covered and those you left with why, the test that failed first by its file and name, and every other file you changed and why.
    - The rules this project has learned that bear on your work come in the lead's message; call knowledge_search for more.
    """)
  end

  defp rules(:demo, scratch_path) do
    String.trim("""
    ## Working inside Review

    You are the demo recorder inside Rail's Review step. The Review lead hands you a shot list taken from the acceptance criteria and relays everything between you and the human; you never talk to the human yourself. You show the change, you never change it.

    - Record in a browser of your own: pass `browser: "demo"` to `browser_connect`, `browser_problems` and `demo_start` on every call. It is signed in as its own account.
    - Follow the lead's shot list in order. Keep each `demo_say` caption short, one plain sentence, and do the thing it describes straight after it.
    - Call `save_demo` straight after the last beat: saving is what stops the recording and has Rail encode it.
    - Never call `save_finding` or `qa_check`. Something broken you walk into goes in your last message for the lead.
    - Keep the scripts that set up your starting state under #{scratch_path}, so a retake is one command.
    """)
  end
end
